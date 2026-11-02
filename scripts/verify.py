#!/usr/bin/env python3
"""Verify the deployed server's certificate, auth, original bytes, and range support."""
from pathlib import Path
import hashlib, http.client, json, plistlib, ssl
from urllib.parse import urlsplit
ROOT = Path(__file__).resolve().parent.parent
p = plistlib.loads((ROOT/'ios/MyMusic/Connection.plist').read_bytes())
u = urlsplit(p['ServerURL'])
def request(path, headers=None, auth=True):
    c = http.client.HTTPSConnection(u.hostname,u.port,context=ssl._create_unverified_context(),timeout=90)
    c.connect()
    if hashlib.sha256(c.sock.getpeercert(binary_form=True)).hexdigest() != p['CertificateSHA256']:
        c.close()
        raise RuntimeError('Certificate mismatch; no credentials sent')
    h = dict(headers or {})
    if auth: h['Authorization'] = 'Bearer ' + p['ServerToken']
    c.request('GET',path,headers=h); response=c.getresponse(); data=response.read(); status=response.status; c.close()
    return status,data
if __name__ == '__main__':
    (ROOT/'artifacts').mkdir(exist_ok=True)
    assert request('/v1/library',auth=False)[0] == 401
    status,data=request('/v1/library'); assert status == 200
    library=json.loads(data); tracks=library['tracks']; assert tracks
    print('Library:',len(tracks),'tracks;',len({t['albumArtist']+'|'+t['album'] for t in tracks}),'albums;',sum(t['lossless'] for t in tracks),'lossless;',library['scanErrors'],'unreadable files')
    (ROOT/'artifacts/library.json').write_bytes(data)
    track=min((t for t in tracks if t['lossless'] and t['format']=='FLAC' and t['duration'] > 20),key=lambda t:t['bytes'])
    status,data=request('/v1/tracks/'+track['id']+'/file'); assert status==200 and len(data)==track['bytes'] and data[:4]==b'fLaC'
    (ROOT/'artifacts/test-track.flac').write_bytes(data)
    (ROOT/'artifacts/test-track.json').write_text(json.dumps(track))
    status,chunk=request('/v1/tracks/'+track['id']+'/file',{'Range':'bytes=100-1099'}); assert status==206 and chunk==data[100:1100]
    status,chunk=request('/v1/tracks/'+track['id']+'/file',{'Range':f'bytes={len(data)}-'}); assert status==416
    print('Verified FLAC:',track['title'],';',track['format'],track['bitDepth'],track['sampleRate'],';',len(data),'bytes; SHA256',hashlib.sha256(data).hexdigest())
    print('Authentication, pinned certificate, full-file delivery, byte ranges, and invalid ranges passed.')
