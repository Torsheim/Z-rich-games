"""Exercise the real local Auth, email, RLS and account-deletion endpoints."""
import json
import re
import time
import uuid
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

config = json.loads((Path(__file__).resolve().parents[1] / 'config.local.json').read_text())
base = config['SUPABASE_URL']
if base not in ('http://127.0.0.1:54321', 'http://localhost:54321'):
    raise SystemExit('This test only runs against the local development backend.')
key = config['SUPABASE_ANON_KEY']
email = f'test-{uuid.uuid4().hex[:10]}@example.com'
username = 'test_' + uuid.uuid4().hex[:12]
password = 'First-test-password-123!'
new_password = 'Second-test-password-456!'


def call(path, body=None, token=None, method=None):
    headers = {'apikey': key, 'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    request = Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                      headers=headers, method=method)
    try:
        with urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except HTTPError as error:
        return error.code, json.loads(error.read())


def code_from_mail():
    for _ in range(30):
        with urlopen('http://127.0.0.1:54324/api/v1/messages') as response:
            messages = json.load(response)['messages']
        for message in messages:
            if any(recipient['Address'] == email for recipient in message['To']):
                with urlopen('http://127.0.0.1:54324/api/v1/message/' + message['ID']) as response:
                    detail = json.load(response)
                match = re.search(r'\b\d{6,10}\b', detail['Text'])
                if match:
                    return match.group()
        time.sleep(0.3)
    raise AssertionError('No verification code arrived in the local mailbox.')

status, signup = call('/auth/v1/signup', {'email': email, 'password': password,
                                         'data': {'username': username}})
assert status == 200, (status, signup)
assert 'access_token' not in signup, 'Signup must require email confirmation.'
status, _ = call('/auth/v1/token?grant_type=password', {'email': email, 'password': password})
assert status == 400, 'Unverified email must not sign in.'
status, _ = call('/auth/v1/verify', {'email': email, 'token': '000000', 'type': 'signup'})
assert status >= 400
status, verified = call('/auth/v1/verify', {'email': email, 'token': code_from_mail(), 'type': 'signup'})
assert status == 200, (status, verified)
token = verified['access_token']
user_id = verified['user']['id']
status, profile = call('/rest/v1/profiles?select=*', token=token)
assert status == 200 and len(profile) == 1 and profile[0]['username'] == username
status, anonymous_profiles = call('/rest/v1/profiles?select=*')
assert status in (401, 403), 'Anonymous profile access must be denied.'
status, write_result = call('/rest/v1/profiles?id=eq.' + user_id, {'username': 'changed_name'}, token=token, method='PATCH')
assert status in (401, 403, 405), ('Direct profile writes must be denied.', status, write_result)
print('PASS: signup, email confirmation, profile creation and access protection')

status, session = call('/auth/v1/token?grant_type=password', {'email': email, 'password': password})
assert status == 200
status, refreshed = call('/auth/v1/token?grant_type=refresh_token', {'refresh_token': session['refresh_token']})
assert status == 200 and refreshed['user']['id'] == user_id
print('PASS: login and session refresh')
# Wait for the recovery message before reading its code.
status, _ = call('/auth/v1/recover', {'email': email})
assert status == 200
# Mailpit returns newest messages first; wait for the recovery mail.
for _ in range(30):
    with urlopen('http://127.0.0.1:54324/api/v1/messages') as response:
        messages = json.load(response)['messages']
    if any('Reset' in m['Subject'] and any(r['Address'] == email for r in m['To']) for m in messages):
        break
    time.sleep(0.3)
status, recovery = call('/auth/v1/verify', {'email': email, 'token': code_from_mail(), 'type': 'recovery'})
assert status == 200, (status, recovery)
token = recovery['access_token']
status, _ = call('/auth/v1/user', {'password': new_password}, token=token, method='PUT')
assert status == 200
status, _ = call('/auth/v1/token?grant_type=password', {'email': email, 'password': password})
assert status == 400
status, session = call('/auth/v1/token?grant_type=password', {'email': email, 'password': new_password})
assert status == 200
token = session['access_token']
print('PASS: password reset; old password rejected')
status, _ = call('/functions/v1/delete-account', {'password': new_password})
assert status == 401
status, _ = call('/functions/v1/delete-account', {'password': 'wrong-password'}, token=token)
assert status == 403, status
status, _ = call('/functions/v1/delete-account', {'password': new_password}, token=token)
assert status == 200, status
status, remaining = call('/rest/v1/profiles?select=*', token=token)
assert status == 200 and remaining == [], 'Profile must cascade-delete.'
status, _ = call('/auth/v1/token?grant_type=password', {'email': email, 'password': new_password})
assert status == 400
print('PASS: deletion requires auth and correct password; Auth user and profile removed')
