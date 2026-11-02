"""Read-only, original-byte music library. No Plex, transcoding, or media writes."""
import asyncio
from contextlib import asynccontextmanager
import hashlib
import hmac
import json
import os
from pathlib import Path
import threading
import time

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse, Response
import mutagen
from mutagen.flac import FLAC
from mutagen.mp4 import MP4
from mutagen.wave import WAVE
from mutagen.aiff import AIFF

ROOT = Path(os.environ.get('MUSIC_ROOT', '/music')).resolve()
STATE = Path(os.environ.get('STATE_ROOT', '/state'))
TOKEN = os.environ.get('UNDERTONE_TOKEN', '')
EXTENSIONS = {'.flac', '.m4a', '.mp3', '.aac', '.wav', '.aif', '.aiff', '.alac'}
MIMES = {'.flac':'audio/flac','.m4a':'audio/mp4','.alac':'audio/mp4','.mp3':'audio/mpeg','.aac':'audio/aac','.wav':'audio/wav','.aif':'audio/aiff','.aiff':'audio/aiff'}
lock = threading.Lock()
catalog = {}
scanning = False
last_scan = 0.0
scan_errors = 0


def authorized(authorization: str = Header(default='')):
    if len(TOKEN) < 32 or not hmac.compare_digest(authorization.encode('utf-8'), ('Bearer ' + TOKEN).encode('utf-8')):
        raise HTTPException(401, 'Pair this device with your library.')


def contained(path):
    resolved = path.resolve()
    if not resolved.is_relative_to(ROOT):
        raise ValueError('Path outside library')
    return resolved


def tag(audio, *keys, fallback=''):
    tags = audio.tags or {}
    for key in keys:
        value = tags.get(key)
        if value:
            if isinstance(value, (list, tuple)): value = value[0]
            if hasattr(value, 'text'): value = value.text[0]
            return str(value)
    return fallback


def inspect(path, stat, identity):
    audio = mutagen.File(path)
    if audio is None or not getattr(audio, 'info', None): return None
    info = audio.info
    title = tag(audio, 'title', '\xa9nam', 'TIT2', fallback=path.stem)
    artist = tag(audio, 'artist', '\xa9ART', 'TPE1', fallback=path.parent.name)
    album = tag(audio, 'album', '\xa9alb', 'TALB', fallback='Singles')
    album_artist = tag(audio, 'albumartist', 'aART', 'TPE2', fallback=artist)
    codec = getattr(info, 'codec', '')
    lossless = isinstance(audio, (FLAC, WAVE, AIFF)) or (isinstance(audio, MP4) and codec == 'alac')
    fmt = 'ALAC' if codec == 'alac' else path.suffix[1:].upper()
    if isinstance(audio, MP4) and not lossless: fmt = 'AAC'
    number = tag(audio, 'tracknumber', 'TRCK', fallback='0').split('/')[0]
    if isinstance(audio, MP4): number = str((audio.tags or {}).get('trkn', [(0,0)])[0][0])
    return dict(id=identity, title=title, artist=artist, album=album, albumArtist=album_artist,
        duration=round(info.length, 3), bytes=stat.st_size, format=fmt,
        fileExtension=path.suffix[1:].lower(), lossless=lossless,
        sampleRate=getattr(info,'sample_rate',0), bitDepth=getattr(info,'bits_per_sample',0),
        bitrate=getattr(info,'bitrate',0), trackNumber=int(number) if number.isdigit() else 0,
        added=stat.st_mtime, relative=str(path.relative_to(ROOT)))


def scan():
    global catalog, scanning, last_scan, scan_errors
    with lock:
        if scanning: return
        scanning = True
    try:
        if not ROOT.is_dir(): raise RuntimeError('Music folder is unavailable')
        fresh = {}; errors = 0
        first_scan = not catalog
        for path in ROOT.rglob('*'):
            if path.suffix.lower() not in EXTENSIONS or not path.is_file() or path.name.startswith('._'): continue
            try:
                contained(path)
                stat = path.stat()
                # Ignore files a producer is still writing; stable files appear on next scan.
                if time.time() - stat.st_mtime < 30: continue
                identity = hashlib.sha256(f'{path.relative_to(ROOT)}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest()[:32]
                entry = catalog.get(identity) or inspect(path, stat, identity)
                if entry:
                    fresh[identity] = entry
                    if first_scan and len(fresh) % 50 == 0:
                        catalog = dict(fresh)
                    if len(fresh) % 500 == 0:
                        print('Indexed', len(fresh), 'tracks', flush=True)
            except Exception: errors += 1
        STATE.mkdir(parents=True, exist_ok=True)
        temporary = STATE/'catalog.tmp'
        temporary.write_text(json.dumps(fresh, ensure_ascii=False))
        temporary.replace(STATE/'catalog.json')
        catalog = fresh; last_scan = time.time(); scan_errors = errors
    finally:
        scanning = False


async def scanner():
    while True:
        try: await asyncio.to_thread(scan)
        except Exception as error: print('Library scan failed:', type(error).__name__, flush=True)
        await asyncio.sleep(300)


@asynccontextmanager
async def lifespan(app):
    global catalog
    if len(TOKEN) < 32: raise RuntimeError('Set a random UNDERTONE_TOKEN of at least 32 characters')
    try: catalog = json.loads((STATE/'catalog.json').read_text())
    except (OSError, ValueError): pass
    task = asyncio.create_task(scanner())
    yield
    task.cancel()


app = FastAPI(title='MyMusic', lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware('http')
async def private_responses(request, call_next):
    response = await call_next(request)
    # Authenticated content and authorization failures must not reach shared caches.
    response.headers['Cache-Control'] = 'private, no-store, no-transform'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    return response


@app.get('/health')
def health(): return {'ok': True}


@app.get('/v1/library', dependencies=[Depends(authorized)])
def library():
    entries = sorted(catalog.values(), key=lambda t: (t['albumArtist'].casefold(),t['album'].casefold(),t['trackNumber'],t['title']))
    return {'tracks': [{k:v for k,v in t.items() if k != 'relative'} for t in entries], 'scanning': scanning, 'lastScan': last_scan, 'scanErrors': scan_errors}


@app.post('/v1/scan', dependencies=[Depends(authorized)])
async def rescan():
    await asyncio.to_thread(scan)
    return {'count':len(catalog), 'scanErrors':scan_errors}


def track_path(track_id):
    entry = catalog.get(track_id)
    if not entry: raise HTTPException(404, 'Track is no longer in the library. Refresh to update it.')
    try:
        path = contained(ROOT/entry['relative'])
        stat = path.stat()
        identity = hashlib.sha256(f'{path.relative_to(ROOT)}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest()[:32]
        if identity != track_id: raise ValueError('File changed')
        return path
    except (OSError, ValueError): raise HTTPException(404, 'Source file changed or is unavailable. Refresh your library.')


@app.api_route('/v1/tracks/{track_id}/file', methods=['GET','HEAD'], dependencies=[Depends(authorized)])
def media(track_id: str):
    path = track_path(track_id)
    return FileResponse(path, media_type=MIMES[path.suffix.lower()], headers={'Cache-Control':'private, no-transform','ETag':f'"{track_id}"'})


@app.get('/v1/tracks/{track_id}/art', dependencies=[Depends(authorized)])
def artwork(track_id: str):
    path = track_path(track_id)
    audio = mutagen.File(path)
    data = None; mime = 'image/jpeg'
    if getattr(audio, 'pictures', None): data = audio.pictures[0].data; mime = audio.pictures[0].mime
    elif isinstance(audio, MP4) and (audio.tags or {}).get('covr'):
        picture = audio.tags['covr'][0]; data = bytes(picture); mime = 'image/png' if picture.imageformat == 14 else 'image/jpeg'
    elif getattr(audio, 'tags', None) and hasattr(audio.tags, 'getall'):
        pictures = audio.tags.getall('APIC')
        if pictures: data = pictures[0].data; mime = pictures[0].mime
    if data and len(data) < 20*1024*1024:
        return Response(data, media_type=mime, headers={'Cache-Control':'private, max-age=86400'})
    for name in ['cover.jpg','folder.jpg','cover.png','folder.png','Cover.jpg','Folder.jpg']:
        candidate = path.parent/name
        try: candidate = contained(candidate)
        except ValueError: continue
        if candidate.is_file(): return FileResponse(candidate, headers={'Cache-Control':'private, max-age=86400'})
    raise HTTPException(404, 'No artwork')
