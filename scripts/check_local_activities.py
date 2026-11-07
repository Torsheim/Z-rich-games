"""Exercise private invitations, drafts, publishing, capacity and approval rules."""
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


from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor


def details(**changes):
    return {'title': 'Integration activity', 'description': 'A local test plan',
            'category_id': 'social', 'city_id': 'zurich', 'timezone': 'Europe/Zurich',
            'place_name': 'The meeting point', 'visibility': 'invite_only',
            'join_policy': 'invitation_required', 'max_participants': 2,
            'starts_at': (datetime.now(timezone.utc) + timedelta(days=2)).isoformat(),
            'status': 'active', **changes}


def create(owner, data=None, invited=None):
    status, result = rpc('create_activity', owner[0], details=data or details(), friend_ids=invited or [])
    assert status == 200, (status, result)
    return result


def feed(user):
    status, rows = rpc('activity_feed', user[0])
    assert status == 200, rows
    return {row['id']: row for row in rows}


try:
    a, b, c = register(), register(), register()
    invite = rpc('my_friend_invite', a[0])[1][0]['token']
    assert rpc('accept_friend_invite', b[0], invite_token=invite)[0] in (200, 204)
    assert rpc('create_activity', a[0], details=details(), friend_ids=[c[1]])[0] >= 400
    assert rpc('create_activity', a[0], details=details(kind='event'), friend_ids=[])[0] >= 400
    assert rpc('create_activity', a[0], details=details(max_participants=0), friend_ids=[])[0] >= 400
    assert rpc('create_activity', None, details=details(), friend_ids=[])[0] >= 400
    private = create(a, invited=[b[1]])
    assert feed(b)[private]['invite_status'] == 'pending'
    assert private not in feed(c)
    assert call('/rest/v1/activities?id=eq.' + private, token=c[0])[1] == []
    assert rpc('respond_to_activity', c[0], target_activity_id=private, response='attend')[0] >= 400
    assert rpc('respond_to_activity', b[0], target_activity_id=private, response='attend')[1] == 'confirmed'
    assert feed(a)[private]['participant_count'] == 2
    assert rpc('respond_to_activity', b[0], target_activity_id=private, response='attend')[1] == 'confirmed'
    assert feed(a)[private]['participant_count'] == 2
    assert rpc('publish_activity', c[0], target_activity_id=private, new_visibility='public', new_join_policy='instant')[0] >= 400
    assert rpc('publish_activity', a[0], target_activity_id=private, new_visibility='public', new_join_policy='instant')[0] in (200, 204)
    assert private in feed(c)
    assert rpc('respond_to_activity', c[0], target_activity_id=private, response='attend')[0] >= 400
    assert rpc('respond_to_activity', b[0], target_activity_id=private, response='decline')[1] == 'cancelled'
    assert feed(b)[private]['invite_status'] == 'declined'
    assert rpc('respond_to_activity', c[0], target_activity_id=private, response='attend')[1] == 'confirmed'
    assert rpc('publish_activity', a[0], target_activity_id=private, new_visibility='invite_only', new_join_policy='invitation_required')[0] in (200, 204)
    assert private in feed(c), 'Existing participant retains access when made private.'
    assert rpc('respond_to_activity', c[0], target_activity_id=private, response='decline')[1] == 'cancelled'
    assert private not in feed(c)
    assert rpc('respond_to_activity', b[0], target_activity_id=private, response='attend')[1] == 'confirmed'
    print('PASS: friend-only invitations, private access, RSVP changes, publication and capacity')
    draft = create(a, details(status='draft'), [b[1]])
    assert draft not in feed(b)
    assert rpc('publish_activity', a[0], target_activity_id=draft, new_visibility='invite_only', new_join_policy='invitation_required')[0] in (200, 204)
    assert draft in feed(b)
    print('PASS: drafts remain host-only until activated')
    approval = create(a, details(visibility='public', join_policy='approval_required'))
    assert rpc('respond_to_activity', c[0], target_activity_id=approval, response='attend')[1] == 'requested'
    assert feed(a)[approval]['participant_count'] == 1
    assert rpc('activity_host_roster', b[0], target_activity_id=approval)[0] >= 400
    assert rpc('review_activity_request', b[0], target_activity_id=approval, participant_user_id=c[1], approve=True)[0] >= 400
    assert rpc('review_activity_request', a[0], target_activity_id=approval, participant_user_id=c[1], approve=True)[0] in (200, 204)
    assert feed(c)[approval]['my_status'] == 'confirmed'
    assert rpc('respond_to_activity', b[0], target_activity_id=approval, response='attend')[1] == 'requested'
    assert rpc('review_activity_request', a[0], target_activity_id=approval, participant_user_id=b[1], approve=True)[0] >= 400
    assert rpc('publish_activity', a[0], target_activity_id=approval, new_visibility='invite_only', new_join_policy='invitation_required')[0] in (200, 204)
    assert feed(a)[approval]['participant_count'] == 2
    print('PASS: host approval, roster privacy and capacity on approval')
    race = create(a, details(visibility='public', join_policy='instant'))
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda user: rpc('respond_to_activity', user[0], target_activity_id=race, response='attend'), [b,c]))
    assert sum(status == 200 for status, _ in results) == 1, results
    assert feed(a)[race]['participant_count'] == 2
    assert call('/rest/v1/activities?id=eq.' + race, {'title':'Forged'}, token=c[0], method='PATCH')[0] >= 400
    print('PASS: simultaneous last-place attempts cannot exceed capacity; direct writes denied')
finally:
    for account in accounts:
        assert call('/functions/v1/delete-account', {'password': password}, token=account[0])[0] == 200
