#!/usr/bin/env python3
"""Generate private pairing material. Run locally, then copy server/ to your server."""
import argparse
import hashlib
import ipaddress
import os
import plistlib
import secrets
import subprocess
from pathlib import Path

# Apply restrictive permissions at creation, including temporary private keys.
os.umask(0o077)

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--music-path', help='Absolute music directory on the server')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
server = root / 'server'
tls = server / 'tls'
tls.mkdir(exist_ok=True)
env = server / '.env'
values = {}
if env.exists():
    values = dict(line.split('=', 1) for line in env.read_text().splitlines() if '=' in line)
token = values.get('UNDERTONE_TOKEN') or secrets.token_urlsafe(48)
if len(token) < 32 or not token.isascii() or any(c.isspace() for c in token):
    parser.error('Existing token must have at least 32 ASCII characters and no whitespace.')
music_path = args.music_path or values.get('UNDERTONE_MUSIC_PATH')
if not music_path or not music_path.startswith('/') or any(c in music_path for c in '\r\n'):
    parser.error('Music path must be an absolute single-line directory.')
try:
    ipaddress.ip_address(args.host)
    san = 'IP:' + args.host
except ValueError:
    if not all(c.isalnum() or c in '.-' for c in args.host):
        raise SystemExit('Use an IP address or hostname.')
    san = 'DNS:' + args.host
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
    '-keyout', str(tls / 'key.pem'), '-out', str(tls / 'cert.pem'), '-subj', '/CN=MyMusic Library',
    '-addext', 'subjectAltName=' + san], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.chmod(tls / 'key.pem', 0o600)
cert = subprocess.check_output(['openssl', 'x509', '-in', str(tls / 'cert.pem'), '-outform', 'DER'])
env.write_text('UNDERTONE_TOKEN=' + token + '\nUNDERTONE_BIND_IP=' + args.host + '\nUNDERTONE_MUSIC_PATH=' + music_path + '\n')
os.chmod(env, 0o600)
connection = root / 'ios/MyMusic/Connection.plist'
config = plistlib.loads(connection.read_bytes()) if connection.exists() else {}
config.update(ServerURL='https://' + args.host + ':8448', ServerToken=token, CertificateSHA256=hashlib.sha256(cert).hexdigest())
connection.write_bytes(plistlib.dumps(config)); os.chmod(connection, 0o600)
print('Pairing created without printing secrets.')
