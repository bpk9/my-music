import os
from pathlib import Path
import tempfile
import time
import unittest
import wave
from fastapi.testclient import TestClient
import app

class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name).resolve()
        app.ROOT=self.root/'music'; app.ROOT.mkdir()
        app.STATE=self.root/'state'; app.TOKEN='test-token-'+'a'*40; app.catalog={}; app.scanning=False
        self.file=app.ROOT/'Song.wav'
        with wave.open(str(self.file),'wb') as audio:
            audio.setnchannels(2); audio.setsampwidth(2); audio.setframerate(44100); audio.writeframes(bytes(44100*4))
        os.utime(self.file,(time.time()-60,time.time()-60))
        app.scan(); self.track=next(iter(app.catalog.values()))
        self.client=TestClient(app.app)
        self.headers={'Authorization':'Bearer '+app.TOKEN}
    def tearDown(self): self.client.close(); self.temp.cleanup()
    def test_auth(self):
        for method, path in [('GET','/v1/library'),('GET','/v1/tracks/'+self.track['id']+'/file'),
                             ('HEAD','/v1/tracks/'+self.track['id']+'/file'),
                             ('GET','/v1/tracks/'+self.track['id']+'/art'),('POST','/v1/scan')]:
            self.assertEqual(self.client.request(method,path).status_code,401)
            self.assertEqual(self.client.request(method,path,headers={'Authorization':'Bearer wrong'}).status_code,401)
    def test_non_ascii_auth_rejected(self):
        self.assertEqual(self.client.get('/v1/library',headers=[(b'Authorization',b'Bearer \xff')]).status_code,401)
    def test_private_responses_not_cached(self):
        for headers in [{},self.headers]:
            response=self.client.get('/v1/library',headers=headers)
            self.assertIn('no-store',response.headers['cache-control'])
            self.assertEqual(response.headers['x-content-type-options'],'nosniff')
    def test_public_surface(self):
        self.assertEqual(self.client.get('/health').json(),{'ok':True})
        for path in ['/docs','/redoc','/openapi.json']:
            self.assertEqual(self.client.get(path).status_code,404)
    def test_short_token_fails_closed(self):
        app.TOKEN='short'
        self.assertEqual(self.client.get('/v1/library',headers={'Authorization':'Bearer short'}).status_code,401)
    def test_artwork_symlink_escape_rejected(self):
        outside=self.root/'private.jpg'; outside.write_bytes(b'private image')
        (app.ROOT/'cover.jpg').symlink_to(outside)
        response=self.client.get('/v1/tracks/'+self.track['id']+'/art',headers=self.headers)
        self.assertEqual(response.status_code,404)
        self.assertNotIn(b'private image',response.content)
    def test_metadata_and_no_paths(self):
        data=self.client.get('/v1/library',headers=self.headers).json()['tracks'][0]
        self.assertTrue(data['lossless']); self.assertEqual(data['sampleRate'],44100)
        self.assertNotIn('relative',data); self.assertAlmostEqual(data['duration'],1)
    def test_original_and_ranges(self):
        path='/v1/tracks/'+self.track['id']+'/file'; original=self.file.read_bytes()
        self.assertEqual(self.client.get(path,headers=self.headers).content,original)
        r=self.client.get(path,headers={**self.headers,'Range':'bytes=40-100'})
        self.assertEqual(r.status_code,206); self.assertEqual(r.content,original[40:101])
        r=self.client.get(path,headers={**self.headers,'Range':'bytes=-20'})
        self.assertEqual(r.content,original[-20:])
        self.assertEqual(self.client.get(path,headers={**self.headers,'Range':'bytes=99999999-'}).status_code,416)
        self.assertEqual(int(self.client.head(path,headers=self.headers).headers['content-length']),len(original))
    def test_changed_file_rejected(self):
        self.file.write_bytes(b'changed')
        self.assertEqual(self.client.get('/v1/tracks/'+self.track['id']+'/file',headers=self.headers).status_code,404)
    def test_symlink_escape_rejected(self):
        outside=self.root/'private.wav'; outside.write_bytes(self.file.read_bytes())
        self.file.unlink(); self.file.symlink_to(outside)
        self.assertEqual(self.client.get('/v1/tracks/'+self.track['id']+'/file',headers=self.headers).status_code,404)
        app.scan(); self.assertEqual(len(app.catalog),0)
    def test_new_files_and_removals(self):
        second=app.ROOT/'Next.wav'; second.write_bytes(self.file.read_bytes())
        app.scan(); self.assertEqual(len(app.catalog),1) # skip in-progress new file
        os.utime(second,(time.time()-60,time.time()-60))
        app.scan(); self.assertEqual(len(app.catalog),2)
        self.file.unlink(); app.scan(); self.assertEqual(len(app.catalog),1)
    def test_cache_restart(self):
        previous=app.catalog; app.catalog={}
        import json
        app.catalog=json.loads((app.STATE/'catalog.json').read_text())
        self.assertEqual(app.catalog,previous)
    def test_rogue_track_id(self):
        self.assertEqual(self.client.get('/v1/tracks/unknown/file',headers=self.headers).status_code,404)

if __name__=='__main__': unittest.main()
