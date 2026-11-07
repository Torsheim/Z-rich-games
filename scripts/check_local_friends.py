"""Integration test using real local Auth users, invitations and RLS."""
import json
import re
import time
import uuid
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

config = json.loads((Path(__file__).resolve().parents[1] / 'config.local.json').read_text())
base = config['SUPABASE_URL']
assert base in ('http://127.0.0.1:54321', 'http://localhost:54321'), 'Local test only.'
key = config['SUPABASE_ANON_KEY']
password = 'Friends-test-password-123!'
accounts = []


def call(path, body=None, token=None, method=None):
    headers = {'apikey': key, 'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    try:
        with urlopen(Request(base + path, headers=headers, method=method,
                            data=json.dumps(body).encode() if body is not None else None), timeout=30) as r:
            text = r.read()
            return r.status, json.loads(text) if text else None
    except HTTPError as e:
        return e.code, json.loads(e.read())


def rpc(name, token=None, **params):
    return call('/rest/v1/rpc/' + name, params, token)


def register():
    name = 'friend_' + uuid.uuid4().hex[:12]
    email = name + '@example.com'
    status, result = call('/auth/v1/signup', {'email': email, 'password': password, 'data': {'username': name}})
    assert status == 200, result
    for _ in range(30):
        with urlopen('http://127.0.0.1:54324/api/v1/messages') as r:
            messages = json.load(r)['messages']
        for message in messages:
            if any(recipient['Address'] == email for recipient in message['To']):
                with urlopen('http://127.0.0.1:54324/api/v1/message/' + message['ID']) as r:
                    code = re.search(r'\b\d{6,10}\b', json.load(r)['Text']).group()
                status, verified = call('/auth/v1/verify', {'email': email, 'token': code, 'type': 'signup'})
                assert status == 200, verified
                account = (verified['access_token'], verified['user']['id'], name)
                accounts.append(account)
                return account
        time.sleep(.3)
    raise AssertionError('No verification email.')


try:
    a, b, outsider = register(), register(), register()
    status, invites = rpc('my_friend_invite', a[0])
    assert status == 200, invites
    token = invites[0]['token']
    assert re.fullmatch('[a-f0-9]{64}', token)
    status, preview = rpc('preview_friend_invite', b[0], invite_token=token)
    assert status == 200 and preview[0]['username'] == a[2] and not preview[0]['already_friends']
    assert rpc('my_friends', b[0])[1] == [], 'Preview must not create a friendship.'
    assert rpc('accept_friend_invite', a[0], invite_token=token)[0] >= 400, 'Reject self.'
    assert rpc('accept_friend_invite', None, invite_token=token)[0] >= 400, 'Reject anonymous.'
    assert rpc('accept_friend_invite', b[0], invite_token='f' * 64)[0] >= 400
    assert rpc('accept_friend_invite', b[0], invite_token=token)[0] in (200, 204)
    assert rpc('accept_friend_invite', b[0], invite_token=token)[0] in (200, 204), 'Idempotent acceptance.'
    assert rpc('my_friends', a[0])[1][0]['username'] == b[2]
    assert rpc('my_friends', b[0])[1][0]['username'] == a[2]
    assert len(rpc('my_friends', b[0])[1]) == 1
    assert rpc('my_friends', outsider[0])[1] == []
    assert call('/rest/v1/friendships?select=*', token=outsider[0])[1] == []
    assert call('/rest/v1/friend_invites?select=*', token=b[0])[0] in (401, 403)
    assert call('/rest/v1/profiles?select=*', token=b[0])[1][0]['id'] == b[1]
    low, high = sorted([b[1], outsider[1]])
    assert call('/rest/v1/friendships', {'user_low': low, 'user_high': high}, token=b[0])[0] >= 400
    print('PASS: confirmation-only mutual friendship; self/anonymous/forged-token rejection; duplicates and privacy')
    status, rotated = rpc('my_friend_invite', a[0], rotate=True)
    assert status == 200 and rotated[0]['token'] != token
    assert rpc('preview_friend_invite', outsider[0], invite_token=token)[1] == []
    assert rpc('accept_friend_invite', outsider[0], invite_token=token)[0] >= 400
    assert rpc('accept_friend_invite', outsider[0], invite_token=rotated[0]['token'])[0] in (200, 204)
    print('PASS: replacing invitation revokes old token without affecting existing friends')
    assert call('/functions/v1/delete-account', {'password': password}, token=a[0])[0] == 200
    accounts.remove(a)
    assert rpc('my_friends', b[0])[1] == []
    assert rpc('my_friends', outsider[0])[1] == []
    assert rpc('preview_friend_invite', b[0], invite_token=rotated[0]['token'])[1] == []
    print('PASS: account deletion removes friendships and invitations on both sides')
finally:
    for account in accounts:
        status, _ = call('/functions/v1/delete-account', {'password': password}, token=account[0])
        assert status == 200, 'Test account cleanup failed.'
