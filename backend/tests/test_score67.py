from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest
from sqlalchemy import select, create_engine, text
from sqlalchemy.engine import make_url
from alembic import command as migrations
from alembic.config import Config

from score67.app import create_app, clean_matches
from score67.db import Admin, Board, MatchEvent, Base
from score67.domain import RuleError, apply, elapsed, initial_state


@pytest.fixture
def system(tmp_path, monkeypatch):
    url = os.getenv('TEST_DATABASE_URL', f'sqlite:///{tmp_path}/test.db')
    if not url.startswith('sqlite'):
        # Only disposable test databases may be reset. Never use production here.
        assert make_url(url).database == 'score67_test'
        engine = create_engine(url)
        Base.metadata.drop_all(engine)
        with engine.begin() as db:
            db.execute(text('DROP TABLE IF EXISTS alembic_version'))
        engine.dispose()
    monkeypatch.setenv('DATABASE_URL', url)
    migrations.upgrade(Config(str(Path(__file__).parents[1] / 'alembic.ini')), 'head')
    monkeypatch.setenv('AUTO_CREATE_SCHEMA', 'false')
    monkeypatch.setenv('TRASH_INTERVAL_SECONDS', '0')
    app = create_app(url, secure_cookies=False)
    with TestClient(app) as client:
        yield app, client


def create(client):
    r = client.post('/api/scoreboards', json={})
    assert r.status_code == 201, r.text
    return r.json()


def state(client, slug):
    return client.get(f'/api/s/{slug}/state').json()


def command(client, slug, action, data=None, current=None, command_id=None):
    s = current or state(client, slug)
    return client.post(f'/api/s/{slug}/matches/{s["match_id"]}/commands', json={
        'command_id': command_id or str(uuid4()), 'expected_revision': s['revision'], 'action': action, 'data': data or {}})


def test_football_complete_game_undo_and_archive(system):
    app, client = system
    slug = create(client)['slug']
    s = state(client, slug)
    old_id = s['match_id']
    assert s['home']['name'] == 'Home' and s['away']['score'] == 0
    assert command(client, slug, 'period_start').json()['clock']['running']
    assert command(client, slug, 'score', {'team': 'home', 'points': 1}).json()['home']['score'] == 1
    assert command(client, slug, 'period_end').json()['phase'] == 'break'
    s = command(client, slug, 'period_start').json()
    assert s['period'] == 2 and s['clock']['elapsed_ms'] == 0
    assert s['events'][-1]['clock_ms'] == 0
    ended = command(client, slug, 'game_end').json()
    assert ended['phase'] == 'finished' and not ended['clock']['running']
    restored = command(client, slug, 'undo', {'event_id': ended['events'][-1]['id']}).json()
    assert restored['phase'] == 'period_running' and restored['clock']['running']
    command(client, slug, 'game_end')
    new = command(client, slug, 'new_match').json()
    assert new['match_id'] != old_id and new['home']['score'] == 0
    archived = client.get(f'/api/s/{slug}/matches/{old_id}/state').json()
    assert archived['home']['score'] == 1 and archived['phase'] == 'finished'
    assert command(client, slug, 'score', {'team': 'home', 'points': 1}, current=archived).status_code == 409


def test_retry_is_idempotent_even_after_intervening_update(system):
    _, client = system
    slug = create(client)['slug']
    original = state(client, slug)
    key = str(uuid4())
    assert command(client, slug, 'score', {'team': 'home', 'points': 1}, original, key).status_code == 200
    command(client, slug, 'score', {'team': 'away', 'points': 1})
    again = command(client, slug, 'score', {'team': 'home', 'points': 1}, original, key)
    assert again.json()['home']['score'] == 1
    assert again.json()['away']['score'] == 1
    assert command(client, slug, 'score', {'team': 'away', 'points': 1}, original, key).status_code == 409


def test_parallel_writes_reject_stale_revision(system):
    _, client = system
    slug = create(client)['slug']
    current = state(client, slug)
    with ThreadPoolExecutor(2) as pool:
        responses = list(pool.map(lambda _: command(client, slug, 'score', {'team': 'home', 'points': 1}, current), range(2)))
    assert sorted(r.status_code for r in responses) == [200, 409]
    assert state(client, slug)['home']['score'] == 1


def test_auth_scope_revoke_rotation_and_no_secrets(system):
    app, client = system
    a, b = create(client), create(client)
    outsider = TestClient(app)
    assert command(outsider, a['slug'], 'score', {'team': 'home', 'points': 1}).status_code == 401
    assert outsider.post(f'/api/s/{a["slug"]}/admin/claim', json={'pin': a['pin'], 'label': 'Second'}).status_code == 200
    assert command(outsider, a['slug'], 'score', {'team': 'home', 'points': 1}).status_code == 200
    assert command(outsider, b['slug'], 'score', {'team': 'home', 'points': 1}).status_code == 401
    devices = client.get(f'/api/s/{a["slug"]}/admins').json()
    second = next(d for d in devices if d['label'] == 'Second')
    assert client.delete(f'/api/s/{b["slug"]}/admins/{second["id"]}').status_code == 404
    assert client.delete(f'/api/s/{a["slug"]}/admins/{second["id"]}').status_code == 200
    assert command(outsider, a['slug'], 'score', {'team': 'home', 'points': 1}).status_code == 401
    new_pin = client.post(f'/api/s/{a["slug"]}/pin', json={}).json()['pin']
    assert outsider.post(f'/api/s/{a["slug"]}/admin/claim', json={'pin': a['pin']}).status_code == 401
    assert outsider.post(f'/api/s/{a["slug"]}/admin/claim', json={'pin': new_pin}).status_code == 200
    public = client.get(f'/api/s/{a["slug"]}/state').text
    for secret_field in ('pin_hash', 'token_hash', 'admin_id', 'recovery_email', 'before'):
        assert secret_field not in public
    with app.state.sessions() as db:
        assert db.get(Board, a['slug']).pin_hash != new_pin
        assert len(db.scalar(select(Admin)).token_hash) == 64


def test_pin_lockout_and_creation_rate_limit_persist(system, monkeypatch):
    monkeypatch.setenv("SCOREBOARD_CREATE_LIMIT", "5")
    app, client = system
    b = create(client)
    wrong = '000000' if b['pin'] != '000000' else '111111'
    outsider = TestClient(app)
    for _ in range(5):
        assert outsider.post(f'/api/s/{b["slug"]}/admin/claim', json={'pin': wrong}).status_code == 401
    assert outsider.post(f'/api/s/{b["slug"]}/admin/claim', json={'pin': b['pin']}).status_code == 429
    for _ in range(4):
        create(client)
    assert client.post('/api/scoreboards', json={}).status_code == 429


def test_csrf_body_limits_cookie_flags_and_validation(system):
    _, client = system
    response = client.post('/api/scoreboards', json={})
    assert 'HttpOnly' in response.headers['set-cookie'] and 'SameSite=lax' in response.headers['set-cookie']
    assert response.headers['cache-control'] == 'no-store'
    assert client.post('/api/scoreboards', json={}, headers={'Origin': 'https://evil.example'}).status_code == 403
    assert client.post('/api/scoreboards', content='{}', headers={'Content-Type': 'text/plain'}).status_code == 415
    assert client.post('/api/scoreboards', json={'name': 'x' * 20000}).status_code == 413
    assert client.post('/api/scoreboards', json={'sport': 'unsupported'}).status_code == 422
    assert client.post('/api/scoreboards', json={'recovery_email': 'not-supported@example.com'}).status_code == 422


def test_untimed_mini_game_and_invalid_commands(system):
    _, client = system
    slug = create(client)['slug']
    assert command(client, slug, 'settings', {'period_count': 1, 'period_length_min': 2, 'clock_enabled': False}).status_code == 200
    s = command(client, slug, 'score', {'team': 'away', 'points': 1}).json()
    assert s['events'][-1]['clock_ms'] is None
    assert command(client, slug, 'period_start').json()['clock']['running'] is False
    assert command(client, slug, 'period_end').status_code == 422
    assert command(client, slug, 'score', {'team': 'home', 'points': 3}).status_code == 422
    assert command(client, slug, 'clock_stop').status_code == 422
    assert command(client, slug, 'settings', {'clock_enabled': True}).status_code == 422
    assert command(client, slug, 'settings', {'clock_enabled': True, 'clock_elapsed_ms': 50000}).status_code == 200
    ended = command(client, slug, 'game_end').json()
    assert ended['away']['score'] == 1
    fresh = command(client, slug, 'new_match').json()
    assert fresh['period_count'] == 1 and fresh['period_length_min'] == 2


def test_websocket_initial_snapshot_and_mutation(system):
    _, client = system
    slug = create(client)['slug']
    with client.websocket_connect(f'/ws/s/{slug}') as ws:
        initial = ws.receive_json()
        assert initial['home']['score'] == 0
        command(client, slug, 'score', {'team': 'home', 'points': 1})
        assert ws.receive_json()['home']['score'] == 1
    with client.websocket_connect(f'/ws/s/{slug}') as ws:
        assert ws.receive_json()['home']['score'] == 1


def test_pages_and_shared_language_keys(system):
    _, client = system
    slug = create(client)['slug']
    assert client.get('/').status_code == 200
    assert 'overlay' in client.get(f'/s/{slug}/overlay').text
    assert client.get(f'/s/{slug}').status_code == 200
    assert set(client.get('/i18n/de.json').json()) == set(client.get('/i18n/en.json').json())


def test_clock_math_no_accumulating_drift_and_undo_snapshot():
    s, _, _ = apply(initial_state(), 'period_start', {}, 1000)
    assert elapsed(s, 2701000) == 2700000
    s, _, _ = apply(s, 'clock_adjust', {'seconds': -10}, 2701000)
    assert elapsed(s, 2702000) == 2691000
    after, _, before = apply(s, 'score', {'team': 'home', 'points': 1}, 2702000)
    assert before == {} and after['clock'] == s['clock']
    paused, _, before = apply(after, 'period_end', {}, 2702000)
    assert not paused['clock']['running']
    paused.update(before)
    assert elapsed(paused, 2703000) == 2692000


@pytest.mark.parametrize('data', [{'period_count': 13}, {'period_count': 1.5}, {'period_length_min': 0},
                                  {'clock_enabled': 'false'}, {'home': {'short': 'TOOLONG'}}, {'home': '<script>'}])
def test_invalid_settings(data):
    with pytest.raises(RuleError):
        apply(initial_state(), 'settings', data, 0)


def test_automatic_board_timestamp_and_inline_team_settings(system):
    _, client = system
    slug = create(client)['slug']
    s = state(client, slug)
    assert s['name'].endswith(' UTC')
    assert len(s['name']) == 27
    updated = command(client, slug, 'settings', {'home': {'name': 'FC Hafen', 'short': 'haf', 'color': '#FACC15'}}).json()
    assert updated['home']['name'] == 'FC Hafen' and updated['home']['color'] == '#facc15'
    assert updated['home']['short'] == 'HAF' and updated['away']['short'] == 'GUE'
    assert command(client, slug, 'settings', {'home': {'short': 'HAFEN'}}).status_code == 422
    assert updated['away']['name'] == 'Guest'
    assert command(client, slug, 'settings', {'home': {'color': 'url(https://evil.test)'}}).status_code == 422
    with client.websocket_connect(f'/ws/s/{slug}') as ws:
        assert ws.receive_json()['home']['color'] == '#facc15'


def test_minus_goal_is_audited_idempotent_and_cannot_be_negative(system):
    _, client = system
    slug = create(client)['slug']
    assert command(client, slug, 'score_correction', {'team': 'home', 'points': -1}).status_code == 422
    command(client, slug, 'score', {'team': 'home', 'points': 1})
    before = state(client, slug)
    key = str(uuid4())
    corrected = command(client, slug, 'score_correction', {'team': 'home', 'points': -1}, before, key).json()
    assert corrected['home']['score'] == 0
    assert corrected['events'][-1]['type'] == 'score_correction'
    assert command(client, slug, 'score_correction', {'team': 'home', 'points': -1}, before, key).json()['home']['score'] == 0
    assert command(client, slug, 'score_correction', {'team': 'home', 'points': -1}).status_code == 422
    undone = command(client, slug, 'undo', {'event_id': corrected['events'][-1]['id']}).json()
    assert undone['home']['score'] == 1 and undone['events'][-1]['cancelled']


def test_creation_is_unlimited_by_default(system):
    _, client = system
    for _ in range(6):
        create(client)


def test_dashboard_only_lists_authorized_devices_and_existing_games(system):
    app, client = system
    a, b = create(client), create(client)
    assert {x['slug'] for x in client.get('/api/dashboard').json()['boards']} == {a['slug'], b['slug']}
    outsider = TestClient(app)
    assert outsider.get('/api/dashboard').json() == {'boards': []}
    outsider.post(f'/api/s/{a["slug"]}/admin/claim', json={'pin': a['pin'], 'label': 'Dashboard device'})
    boards = outsider.get('/api/dashboard').json()['boards']
    assert len(boards) == 1 and boards[0]['slug'] == a['slug']
    assert boards[0]['matches'][0]['home']['score'] == 0
    admins = client.get(f'/api/s/{a["slug"]}/admins').json()
    device = next(x for x in admins if x['label'] == 'Dashboard device')
    client.delete(f'/api/s/{a["slug"]}/admins/{device["id"]}')
    assert outsider.get('/api/dashboard').json()['boards'] == []


def test_schedule_is_idempotent_and_does_not_replace_live_game(system):
    import time
    _, client = system
    slug = create(client)['slug']
    original = command(client, slug, 'period_start').json()
    payload = {'command_id': str(uuid4()), 'home': 'Harbor', 'away': 'Town',
               'scheduled_at': int((time.time()+86400)*1000), 'period_count': 1, 'period_length_min': 10}
    created = client.post(f'/api/s/{slug}/matches', json=payload)
    assert created.status_code == 201
    assert client.post(f'/api/s/{slug}/matches', json=payload).status_code == 201
    games = client.get('/api/dashboard').json()['boards'][0]['matches']
    assert len(games) == 2 and state(client, slug)['match_id'] == original['match_id']
    scheduled = next(x for x in games if x['match_id'] != original['match_id'])
    assert scheduled['scheduled_at'] == payload['scheduled_at']
    assert command(client, slug, 'activate', current=scheduled).status_code == 409
    command(client, slug, 'game_end')
    active = command(client, slug, 'activate', current=scheduled).json()
    assert active['home']['name'] == 'Harbor' and active['phase'] == 'pre_game'
    assert active['period_count'] == 1


def test_archive_restore_delete_and_empty_live_state(system):
    _, client = system
    slug = create(client)['slug']
    command(client, slug, 'period_start')
    assert command(client, slug, 'archive').status_code == 409
    old = command(client, slug, 'game_end').json()
    empty = command(client, slug, 'archive').json()
    assert empty['match_id'] is None and empty['overlay']['view'] == 'hidden'
    with client.websocket_connect(f'/ws/s/{slug}') as ws:
        assert ws.receive_json()['match_id'] is None
    archived = client.get('/api/dashboard').json()['boards'][0]['matches'][0]
    assert archived['archived']
    assert command(client, slug, 'activate', current=archived).status_code == 409
    assert command(client, slug, 'restore', current=archived).status_code == 200
    restored = client.get('/api/dashboard').json()['boards'][0]['matches'][0]
    assert not restored['archived']
    key = str(uuid4())
    assert command(client, slug, 'delete', current=restored, command_id=key).status_code == 200
    assert command(client, slug, 'delete', current=restored, command_id=key).status_code == 200
    assert client.get('/api/dashboard').json()['boards'][0]['matches'] == []
    assert client.get(f'/api/s/{slug}/matches/{old["match_id"]}/state').status_code == 410


def test_scheduling_validation_and_cross_board_management(system):
    import time
    app, client = system
    a, b = create(client), create(client)
    payload = {'command_id': str(uuid4()), 'scheduled_at': int((time.time()-60)*1000)}
    assert client.post(f'/api/s/{a["slug"]}/matches', json=payload).status_code == 422
    stranger = TestClient(app)
    assert stranger.post(f'/api/s/{a["slug"]}/matches', json={'command_id': str(uuid4())}).status_code == 401
    other_game = state(client, b['slug'])
    assert command(client, a['slug'], 'delete', current=other_game).status_code == 404
    assert command(client, a['slug'], 'schedule', {'scheduled_at': 'tomorrow'}).status_code == 422
    before = state(client, a['slug'])
    when = int((time.time()+3600)*1000)
    assert command(client, a['slug'], 'schedule', {'scheduled_at':when}).json()['scheduled_at'] == when
    assert command(client, a['slug'], 'delete', current=before).status_code == 409


def test_board_creation_accepts_device_format_defaults(system):
    _, client = system
    b = client.post('/api/scoreboards', json={'period_count':1, 'period_length_min':10}).json()
    s = state(client,b['slug'])
    assert (s['period_count'],s['period_length_min']) == (1,10)


def test_upgrade_preserves_existing_board_match_and_admin(tmp_path, monkeypatch):
    import time
    from sqlalchemy import MetaData, Table
    from score67.app import digest
    from score67.domain import initial_state
    url = os.getenv('TEST_DATABASE_URL', f'sqlite:///{tmp_path}/upgrade.db')
    engine = create_engine(url)
    if not url.startswith('sqlite'):
        assert make_url(url).database == 'score67_test'
        Base.metadata.drop_all(engine)
        with engine.begin() as db:
            db.execute(text('DROP TABLE IF EXISTS alembic_version'))
    monkeypatch.setenv('DATABASE_URL', url)
    config = Config(str(Path(__file__).parents[1] / 'alembic.ini'))
    migrations.upgrade(config, '0001_initial')
    meta = MetaData()
    tables = {name: Table(name, meta, autoload_with=engine) for name in ('scoreboard','scoreboard_admin','match','match_event')}
    slug, match_id, admin_id = 'oldboard01', str(uuid4()), str(uuid4())
    with engine.begin() as db:
        db.execute(tables['scoreboard'].insert().values(slug=slug,name='Existing board',language='en',pin_hash='hash',failed_count=0,locked_until=0,active_match=match_id,created_at=1000))
        db.execute(tables['scoreboard_admin'].insert().values(id=admin_id,slug=slug,token_hash=digest('migration-test'),label='Existing device',last_seen_at=time.time(),revoked=False))
        db.execute(tables['match'].insert().values(id=match_id,slug=slug,revision=1,state=initial_state()))
        db.execute(tables['match_event'].insert().values(match_id=match_id,admin_id=admin_id,payload={'type':'score','team':'home','points':1},before={},cancelled=False))
    migrations.upgrade(config, 'head')
    monkeypatch.setenv('AUTO_CREATE_SCHEMA', 'false')
    monkeypatch.setenv('TRASH_INTERVAL_SECONDS', '0')
    with TestClient(create_app(url,secure_cookies=False)) as client:
        client.cookies.set(f'score67_{slug}', 'migration-test')
        s = state(client,slug)
        assert s['home']['score'] == 1 and s['match_id'] == match_id
        assert s['created_at'] == 1000000
        assert client.get('/api/dashboard').json()['boards'][0]['slug'] == slug
    engine.dispose()


def test_red_cards_correct_undo_retry_and_new_game(system):
    app, client = system
    slug = create(client)['slug']
    original = state(client, slug)
    assert original['home']['counters']['red_cards'] == 0
    assert command(client, slug, 'red_card_correction', {'team': 'home'}).status_code == 422
    assert command(client, slug, 'red_card', {'team': 'other'}).status_code == 422
    outsider = TestClient(app)
    assert command(outsider, slug, 'red_card', {'team': 'home'}).status_code == 401
    command(client, slug, 'period_start')
    before = state(client, slug)
    key = str(uuid4())
    added = command(client, slug, 'red_card', {'team': 'home'}, before, key).json()
    assert added['home']['counters']['red_cards'] == 1
    assert added['home']['score'] == 0
    assert added['clock'] == before['clock']
    repeated = command(client, slug, 'red_card', {'team': 'home'}, before, key).json()
    assert repeated['home']['counters']['red_cards'] == 1
    command(client, slug, 'red_card', {'team': 'away'})
    removed = command(client, slug, 'red_card_correction', {'team': 'home'}).json()
    assert removed['home']['counters']['red_cards'] == 0
    assert removed['away']['counters']['red_cards'] == 1
    undone = command(client, slug, 'undo', {'event_id': removed['events'][-1]['id']}).json()
    assert undone['home']['counters']['red_cards'] == 1
    with client.websocket_connect(f'/ws/s/{slug}') as ws:
        assert ws.receive_json()['home']['counters']['red_cards'] == 1
    command(client, slug, 'game_end')
    fresh = command(client, slug, 'new_match').json()
    assert fresh['home']['counters']['red_cards'] == fresh['away']['counters']['red_cards'] == 0
    old = client.get(f'/api/s/{slug}/matches/{original["match_id"]}/state').json()
    assert old['home']['counters']['red_cards'] == old['away']['counters']['red_cards'] == 1


def test_public_live_directory_only_running_active_games(system):
    app, client = system
    public = TestClient(app)
    ready = create(client)['slug']
    running = create(client)['slug']
    paused = create(client)['slug']
    ended = create(client)['slug']
    removed = create(client)['slug']
    command(client, running, 'period_start')
    command(client, running, 'score', {'team': 'home', 'points': 1})
    command(client, running, 'red_card', {'team': 'away'})
    command(client, paused, 'period_start')
    command(client, paused, 'period_end')
    command(client, ended, 'game_end')
    command(client, removed, 'delete')
    response = public.get('/api/live')
    assert response.status_code == 200 and response.headers['cache-control'] == 'no-store'
    assert not response.headers.get('set-cookie')
    games = {g['scoreboard']: g for g in response.json()['games']}
    assert set(games) == {running, paused}
    assert games[running]['home']['score'] == 1
    assert games[running]['away']['counters']['red_cards'] == 1
    assert games[paused]['phase'] == 'break'
    assert set(games[running]) == {'sport', 'team_fouls_enabled', 'overtime_length_min', 'scoreboard', 'match_id', 'home', 'away', 'clock', 'phase', 'period', 'period_count', 'period_length_min', 'server_now', 'location', 'description', 'stream_url'}
    command(client, running, 'game_end')
    assert [g['scoreboard'] for g in public.get('/api/live').json()['games']] == [paused]
    command(client, paused, 'game_end')
    assert public.get('/api/live').json()['games'] == []
    assert public.get('/live').status_code == 200
    assert '/static/share.mjs' in public.get(f'/s/{ready}').text
    assert '/static/share.mjs' not in public.get(f'/s/{ready}/overlay').text


def test_optional_location_privacy_update_and_removal(system):
    app, client = system
    public = TestClient(app)
    private = {'lat': 53.551, 'lng': 9.994, 'label': 'Private venue', 'visible': False}
    r = client.post('/api/scoreboards', json={'location': private})
    assert r.status_code == 201
    slug = r.json()['slug']
    assert client.get(f'/api/s/{slug}/location').json()['location'] == private
    assert public.get(f'/api/s/{slug}/location').status_code == 401
    assert public.put(f'/api/s/{slug}/location', json={'location': private}).status_code == 401
    assert state(public, slug)['location'] is None
    command(client, slug, 'period_start')
    assert public.get('/api/live').json()['games'][0]['location'] is None
    for endpoint in [f'/api/s/{slug}/state', '/api/live']:
        assert 'Private venue' not in public.get(endpoint).text
        assert '53.551' not in public.get(endpoint).text
    with public.websocket_connect(f'/ws/s/{slug}') as ws:
        assert ws.receive_json()['location'] is None
        shown = {**private, 'visible': True}
        assert client.put(f'/api/s/{slug}/location', json={'location': shown}).status_code == 200
        assert ws.receive_json()['location'] == {k: shown[k] for k in ('lat','lng','label')}
        assert client.put(f'/api/s/{slug}/location', json={'location': private}).status_code == 200
        assert ws.receive_json()['location'] is None
    assert 'Private venue' not in public.get('/api/live').text
    assert client.put(f'/api/s/{slug}/location', json={'location': None}).status_code == 200
    assert client.get(f'/api/s/{slug}/location').json()['location'] is None
    assert state(public, slug)['location'] is None
    assert state(public, create(client)['slug'])['location'] is None
    for invalid in [{**private,'lat':91}, {**private,'lng':181}, {**private,'label':'x'*121}, {'lat':12}]:
        assert client.post('/api/scoreboards', json={'location':invalid}).status_code == 422
        assert client.put(f'/api/s/{slug}/location', json={'location':invalid}).status_code == 422


def test_squad_attribution_corrections_and_undo(system):
    app, client = system
    slug = create(client)['slug']
    alice = {'id': str(uuid4()), 'number': '7', 'name': 'Alice'}
    bob = {'id': str(uuid4()), 'number': '10', 'name': 'Bob'}
    assert command(client, slug, 'squad', {'team': 'home', 'players': [alice, bob]}).status_code == 200
    assert command(TestClient(app), slug, 'squad', {'team': 'home', 'players': []}).status_code == 401
    assert command(client, slug, 'score', {'team': 'away', 'points': 1, 'player_id': alice['id']}).status_code == 422
    started = command(client, slug, 'period_start').json()
    before = state(client, slug)
    key = str(uuid4())
    s = command(client, slug, 'score', {'team': 'home', 'points': 1, 'player_id': alice['id']}, before, key).json()
    goal = s['events'][-1]
    assert goal['player'] == alice and s['home']['score'] == 1
    assert goal['command_id'] == key
    repeated = command(client, slug, 'score', {'team': 'home', 'points': 1, 'player_id': alice['id']}, before, key).json()
    assert repeated['home']['score'] == 1
    changed = command(client, slug, 'assign_player', {'team': 'home', 'event_id': goal['id'], 'player_id': bob['id']}).json()
    assert next(e for e in changed['events'] if e['id'] == goal['id'])['player'] == bob
    assert next(e for e in changed['events'] if e.get('command_id') == key)['id'] == goal['id']
    assert changed['home']['score'] == 1 and changed['clock'] == started['clock']
    restored = command(client, slug, 'undo', {'event_id': changed['events'][-1]['id']}).json()
    assert next(e for e in restored['events'] if e['id'] == goal['id'])['player'] == alice
    card = command(client, slug, 'yellow_card', {'team': 'home', 'player_id': alice['id']}).json()['events'][-1]
    command(client, slug, 'yellow_card', {'team': 'home', 'player_id': bob['id']})
    corrected = command(client, slug, 'yellow_card_correction', {'team': 'home', 'event_id': card['id']}).json()
    assert corrected['home']['counters']['yellow_cards'] == 1 and corrected['home']['counters']['red_cards'] == 0
    assert corrected['events'][-1]['player'] == alice and corrected['events'][-1]['corrects'] == card['id']
    assert next(e for e in corrected['events'] if e['id'] == card['id'])['corrected']
    assert command(client, slug, 'yellow_card_correction', {'team': 'home', 'event_id': card['id']}).status_code == 422
    assert command(client, slug, 'assign_player', {'team': 'home', 'event_id': card['id'], 'player_id': bob['id']}).status_code == 422
    undone = command(client, slug, 'undo', {'event_id': corrected['events'][-1]['id']}).json()
    assert undone['home']['counters']['yellow_cards'] == 2
    command(client, slug, 'yellow_card', {'team': 'home', 'player_id': alice['id']})
    assert state(client, slug)['home']['counters']['red_cards'] == 0
    assert command(client, slug, 'red_card', {'team': 'home', 'player_id': alice['id']}).json()['events'][-1]['player'] == alice
    command(client, slug, 'squad', {'team': 'home', 'players': [{**bob, 'name': 'Renamed'}]})
    assert next(e for e in state(client, slug)['events'] if e['id'] == goal['id'])['player']['name'] == 'Alice'
    removed = command(client, slug, 'score_correction', {'team': 'home', 'points': -1, 'event_id': goal['id']}).json()
    assert removed['home']['score'] == 0 and removed['events'][-1]['player'] == alice
    old = removed['match_id']
    command(client, slug, 'game_end')
    fresh = command(client, slug, 'new_match').json()
    assert fresh['home']['squad'] == [] and fresh['home']['counters']['yellow_cards'] == 0
    assert client.get(f'/api/s/{slug}/matches/{old}/state').json()['home']['squad'][0]['name'] == 'Renamed'


def test_squad_validation_and_unassigned_yellow_cards(system):
    _, client = system
    slug = create(client)['slug']
    a = {'id': str(uuid4()), 'number': '07', 'name': ''}
    b = {'id': str(uuid4()), 'number': '', 'name': 'Name only'}
    accepted = command(client, slug, 'squad', {'team': 'home', 'players': [a,b]}).json()
    assert accepted['home']['squad'][0]['number'] == '7'
    for players in [[a,{**b,'number':'7'}], [a,a], [{**a,'id':'invalid'}], [{**a,'number':'-1'}], [{**b,'name':''}], [{**b,'name':'x'*61}], [b]*41]:
        assert command(client, slug, 'squad', {'team':'home','players':players}).status_code == 422
    assert command(client, slug, 'yellow_card_correction', {'team':'home'}).status_code == 422
    yellow = command(client, slug, 'yellow_card', {'team':'home'}).json()
    assert yellow['events'][-1]['player'] is None and yellow['home']['counters']['yellow_cards'] == 1
    assert command(client, slug, 'assign_player', {'team':'away','event_id':yellow['events'][-1]['id'],'player_id':None}).status_code == 422
    cleared = command(client, slug, 'yellow_card_correction', {'team':'home'}).json()
    assert cleared['home']['counters']['yellow_cards'] == 0
    assert command(client, slug, 'yellow_card_correction', {'team':'home'}).status_code == 422


def test_basketball_ten_stops_expiry_and_remaining_correction():
    s = initial_state(sport='basketball')
    s, _, _ = apply(s, 'period_start', {}, 1000)
    assert s['period'] == 1 and not s['clock']['running']
    now = 1000
    for _ in range(10):
        s, _, _ = apply(s, 'clock_start', {}, now)
        s, _, _ = apply(s, 'clock_stop', {}, now + 1234)
        now += 10000
    assert elapsed(s, now + 999999) == 12340
    s, _, _ = apply(s, 'clock_set', {'remaining_ms': 271000}, now)
    assert elapsed(s, now) == 329000 and not s['clock']['running']
    s, _, _ = apply(s, 'clock_start', {}, now)
    s, event, _ = apply(s, 'score', {'team': 'home', 'points': 3}, now + 300000)
    assert s['phase'] == 'period_running' and not s['clock']['running']
    assert event['clock_ms'] == 600000
    s, _, _ = apply(s, 'clock_adjust', {'seconds': 10}, now + 301000)
    assert elapsed(s, now + 301000) == 590000
    assert not s['clock']['running']
    with pytest.raises(RuleError):
        apply(s, 'clock_set', {'remaining_ms': 600001}, now)
    with pytest.raises(RuleError):
        apply(initial_state(), 'clock_start', {}, now)


@pytest.mark.parametrize('periods,minutes', [(4, 10), (4, 12), (8, 5), (2, 20)])
def test_basketball_formats_fouls_overtime_and_new_game(system, periods, minutes):
    _, client = system
    response = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': periods, 'period_length_min': minutes})
    assert response.status_code == 201
    slug = response.json()['slug']
    s = state(client, slug)
    assert s['sport'] == 'basketball' and s['clock']['direction'] == 'down'
    assert s['team_fouls_enabled'] == (periods != 8)
    command(client, slug, 'settings', {'team_fouls_enabled': True})
    for period in range(1, periods + 1):
        s = command(client, slug, 'period_start').json()
        assert s['period'] == period and s['clock']['elapsed_ms'] == 0
        assert s['home']['counters']['team_fouls'] == 0
        assert not s['clock']['running']
        command(client, slug, 'clock_start')
        command(client, slug, 'team_foul', {'team': 'home'})
        s = command(client, slug, 'timeout', {'team': 'home'}).json()
        assert not s['clock']['running']
        assert s['home']['counters']['timeouts'] == period
        assert s['home']['counters']['team_fouls'] == 1
        assert command(client, slug, 'period_end').json()['phase'] == 'break'
    assert command(client, slug, 'period_start').status_code == 422
    for overtime in (1, 2):
        s = command(client, slug, 'overtime_start').json()
        assert s['period'] == periods + overtime and s['clock']['elapsed_ms'] == 0
        assert s['home']['counters']['team_fouls'] == overtime
        assert s['events'][-1]['period_duration_ms'] == 300000
        command(client, slug, 'team_foul', {'team': 'home'})
        assert command(client, slug, 'clock_set', {'remaining_ms': 300001}).status_code == 422
        command(client, slug, 'period_end')
    command(client, slug, 'score', {'team': 'home', 'points': 2})
    assert command(client, slug, 'overtime_start').status_code == 422
    command(client, slug, 'game_end')
    s = command(client, slug, 'new_match').json()
    assert s['sport'] == 'basketball' and s['period_count'] == periods
    assert s['period_length_min'] == minutes and s['home']['score'] == 0
    assert s['home']['counters']['team_fouls'] == 0


def test_basketball_score_corrections_retry_undo_and_scheduling(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    s = state(client, slug)
    assert (s['period_count'], s['period_length_min']) == (4, 10)
    for points in (1, 2, 3):
        s = command(client, slug, 'score', {'team': 'home', 'points': points}).json()
    assert s['home']['score'] == 6
    target = s['events'][-1]['id']
    key = str(uuid4())
    original = s
    s = command(client, slug, 'score_correction', {'team': 'home', 'event_id': target, 'points': -3}, original, key).json()
    assert s['home']['score'] == 3
    assert command(client, slug, 'score_correction', {'team': 'home', 'event_id': target, 'points': -3}, original, key).json()['home']['score'] == 3
    assert command(client, slug, 'score_correction', {'team': 'home', 'event_id': target}).status_code == 422
    s = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
    assert s['home']['score'] == 6
    assert command(client, slug, 'score_correction', {'team': 'home', 'event_id': target, 'points': -1}).status_code == 422
    assert command(client, slug, 'score', {'team': 'home', 'points': 4}).status_code == 422
    assert command(client, slug, 'red_card', {'team': 'home'}).status_code == 422
    scheduled = client.post(f'/api/s/{slug}/matches', json={
        'command_id': str(uuid4()), 'sport': 'basketball', 'home': 'Sunday Home', 'away': 'Sunday Guest',
        'scheduled_at': 4102444800000, 'period_count': 4, 'period_length_min': 12})
    assert scheduled.status_code == 201
    game = client.get(f'/api/s/{slug}/matches/{scheduled.json()["match_id"]}/state').json()
    assert game['sport'] == 'basketball' and game['phase'] == 'pre_game' and game['period_length_min'] == 12
    games = client.get('/api/dashboard').json()['boards'][0]['matches']
    assert all(g['sport'] == 'basketball' for g in games)
    command(client, slug, 'period_start')
    assert client.get('/api/live').json()['games'][0]['sport'] == 'basketball'


def test_basketball_foul_timeout_corrections_and_sport_isolation(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    command(client, slug, 'period_start')
    command(client, slug, 'clock_start')
    for kind, counter in [('team_foul', 'team_fouls'), ('timeout', 'timeouts')]:
        s = command(client, slug, kind, {'team': 'away'}).json()
        assert s['away']['counters'][counter] == 1
        s = command(client, slug, kind + '_correction', {'team': 'away'}).json()
        assert s['away']['counters'][counter] == 0
        assert command(client, slug, kind + '_correction', {'team': 'away'}).status_code == 422
        s = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
        assert s['away']['counters'][counter] == 1
    assert not s['clock']['running']
    command(client, slug, 'settings', {'team_fouls_enabled': False})
    assert command(client, slug, 'team_foul', {'team': 'away'}).status_code == 422
    football = create(client)['slug']
    assert command(client, football, 'team_foul', {'team': 'home'}).status_code == 422
    assert command(client, football, 'timeout', {'team': 'home'}).status_code == 422
    assert command(client, football, 'score', {'team': 'home', 'points': 2}).status_code == 422


def control_state(client, slug):
    r = client.get(f'/api/s/{slug}/control-state')
    assert r.status_code == 200, r.text
    return r.json()


def test_personal_fouls_both_corrections_undo_and_periods(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': 2}).json()['slug']
    command(client, slug, 'settings', {'foul_mode': 'both'})
    command(client, slug, 'period_start')
    command(client, slug, 'clock_start')
    original = state(client, slug)
    key = str(uuid4())
    s = command(client, slug, 'personal_foul', {'team': 'home', 'player_number': '07'}, original, key).json()
    player = s['home']['personal_fouls'][0]
    assert player['number'] == '7' and player['fouls'] == 1
    assert s['home']['counters']['team_fouls'] == 1 and s['clock']['running']
    repeated = command(client, slug, 'personal_foul', {'team': 'home', 'player_number': '07'}, original, key).json()
    assert repeated['home']['personal_fouls'][0]['fouls'] == 1
    for _ in range(4):
        s = command(client, slug, 'personal_foul', {'team': 'home', 'player_id': player['id']}).json()
    assert s['home']['personal_fouls'][0]['fouls'] == 5 and s['home']['counters']['team_fouls'] == 5
    target = s['events'][-1]['id']
    s = command(client, slug, 'personal_foul_correction', {'team': 'home', 'event_id': target}).json()
    assert s['home']['personal_fouls'][0]['fouls'] == 4 and s['home']['counters']['team_fouls'] == 4
    assert command(client, slug, 'personal_foul_correction', {'team': 'home', 'event_id': target}).status_code == 422
    s = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
    assert s['home']['personal_fouls'][0]['fouls'] == 5 and s['home']['counters']['team_fouls'] == 5
    command(client, slug, 'period_end'); command(client, slug, 'period_start')
    s = control_state(client, slug)
    assert s['home']['personal_fouls'][0]['fouls'] == 5 and s['home']['counters']['team_fouls'] == 0
    command(client, slug, 'personal_foul', {'team': 'home', 'player_id': player['id']})
    command(client, slug, 'period_end'); command(client, slug, 'overtime_start')
    s = control_state(client, slug)
    assert s['home']['personal_fouls'][0]['fouls'] == 6 and s['home']['counters']['team_fouls'] == 1
    old = s['match_id']
    command(client, slug, 'game_end'); s = command(client, slug, 'new_match').json()
    assert s['foul_mode'] == 'both' and s['home']['personal_fouls'] == []
    assert client.get(f'/api/s/{slug}/matches/{old}/control-state').json()['home']['personal_fouls'][0]['fouls'] == 6


def test_personal_foul_unknown_reassignment_modes_and_privacy(system):
    app, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': 8}).json()['slug']
    assert state(client, slug)['foul_mode'] == 'personal'
    s = command(client, slug, 'personal_foul', {'team': 'away'}).json()
    event_id = s['events'][-1]['id']
    assert s['away']['unassigned_fouls'] == 1 and s['away']['personal_fouls'] == []
    assert s['away']['counters']['team_fouls'] == 0
    s = command(client, slug, 'assign_foul_player', {'team': 'away', 'event_id': event_id, 'player_number': '23'}).json()
    assert s['away']['unassigned_fouls'] == 0 and s['away']['personal_fouls'][0]['fouls'] == 1
    player_id = s['away']['personal_fouls'][0]['id']
    assert command(client, slug, 'assign_player', {'team': 'away', 'event_id': event_id, 'player_id': player_id}).status_code == 422
    assert command(client, slug, 'assign_foul_player', {'team': 'home', 'event_id': event_id}).status_code == 422
    s = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
    assert s['away']['unassigned_fouls'] == 1 and s['away']['personal_fouls'] == []
    command(client, slug, 'assign_foul_player', {'team': 'away', 'event_id': event_id, 'player_number': '23'})
    command(client, slug, 'settings', {'foul_mode': 'both'})
    s = command(client, slug, 'personal_foul', {'team': 'away', 'player_number': '23'}).json()
    assert s['away']['personal_fouls'][0]['fouls'] == 2 and s['away']['counters']['team_fouls'] == 1
    command(client, slug, 'period_start')
    public = TestClient(app)
    assert public.get(f'/api/s/{slug}/control-state').status_code == 401
    assert public.get(f'/api/s/{slug}/matches/{s["match_id"]}/control-state').status_code == 401
    def assert_private(data):
        import json
        text = json.dumps(data)
        for secret in ('personal_foul', 'foul_players', 'assign_foul_player', 'unassigned_fouls', '"23"'):
            assert secret not in text
    assert_private(state(client, slug))  # Even the owner's public endpoint is public-only.
    assert_private(public.get(f'/api/s/{slug}/matches/{s["match_id"]}/state').json())
    assert_private(public.get('/api/live').json())
    assert_private(client.get('/api/dashboard').json())
    with public.websocket_connect(f'/ws/s/{slug}') as ws:
        assert_private(ws.receive_json())
    command(client, slug, 'settings', {'foul_mode': 'off'})
    assert command(client, slug, 'personal_foul', {'team': 'away'}).status_code == 422
    assert command(client, slug, 'team_foul', {'team': 'away'}).status_code == 422
    # Turning counting off must not prevent correction of a recorded foul.
    assert command(client, slug, 'personal_foul_correction', {'team': 'away', 'event_id': event_id}).status_code == 200
    outsider_slug = create(public)['slug']
    assert public.get(f'/api/s/{outsider_slug}/matches/{s["match_id"]}/control-state').status_code == 404
    device = next(a for a in client.get(f'/api/s/{slug}/admins').json() if a['current'])
    client.delete(f'/api/s/{slug}/admins/{device["id"]}')
    assert client.get(f'/api/s/{slug}/control-state').status_code == 401


def test_personal_foul_identity_roster_edits_and_validation(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': 8}).json()['slug']
    s = command(client, slug, 'personal_foul', {'team': 'home', 'player_number': '7'}).json()
    identifier = s['home']['personal_fouls'][0]['id']
    roster = [{'id': str(uuid4()), 'number': '07', 'name': 'Alex'}]
    s = command(client, slug, 'squad', {'team': 'home', 'players': roster}).json()
    assert s['home']['squad'][0]['id'] == identifier
    assert s['home']['personal_fouls'][0]['fouls'] == 1
    roster = [{'id': identifier, 'number': '9', 'name': 'Alex updated'}]
    command(client, slug, 'squad', {'team': 'home', 'players': roster})
    s = command(client, slug, 'personal_foul', {'team': 'home', 'player_number': '9'}).json()
    assert len(s['home']['personal_fouls']) == 1 and s['home']['personal_fouls'][0]['fouls'] == 2
    command(client, slug, 'squad', {'team': 'home', 'players': []})
    s = command(client, slug, 'personal_foul', {'team': 'home', 'player_id': identifier}).json()
    assert s['home']['personal_fouls'][0]['fouls'] == 3
    for data in [{'player_number': ''}, {'player_number': '1000'}, {'player_number': 7}, {'player_id': str(uuid4())}, {'player_id': identifier, 'player_number': '9'}]:
        assert command(client, slug, 'personal_foul', {'team': 'home', **data}).status_code == 422
    assert command(client, slug, 'personal_foul', {'team': 'away', 'player_id': identifier}).status_code == 422
    football = create(client)['slug']
    assert command(client, football, 'personal_foul', {'team': 'home'}).status_code == 422
    assert command(client, football, 'settings', {'foul_mode': 'both'}).status_code == 422


def test_basketball_scoring_while_clock_runs_and_numbered_scorer(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    command(client, slug, 'period_start')
    command(client, slug, 'clock_start')
    # Made field goals do not stop the game clock (FIBA), so scoring never requires a stop.
    for points in (1, 2, 3):
        s = command(client, slug, 'score', {'team': 'home', 'points': points}).json()
        assert s['clock']['running']
    assert s['home']['score'] == 6
    command(client, slug, 'clock_stop')
    s = command(client, slug, 'score', {'team': 'home', 'points': 2}).json()
    assert s['home']['score'] == 8 and s['events'][-1]['player'] is None
    player = {'id': str(uuid4()), 'number': '12', 'name': 'Alex'}
    assert command(client, slug, 'squad', {'team': 'home', 'players': [{**player, 'number': ''}]}).status_code == 422
    assert command(client, slug, 'squad', {'team': 'home', 'players': [player]}).status_code == 200
    assert command(client, slug, 'score', {'team': 'home', 'points': 3, 'player_id': str(uuid4())}).status_code == 422
    for extra in ({}, {'player_id': None}):
        s = command(client, slug, 'score', {'team': 'home', 'points': 1, **extra}).json()
        assert s['events'][-1]['player'] is None
    assert s['home']['score'] == 10
    s = command(client, slug, 'score', {'team': 'home', 'points': 3, 'player_id': player['id']}).json()
    assert s['home']['score'] == 13
    assert s['events'][-1]['player'] == player
    command(client, slug, 'clock_start')
    s = command(client, slug, 'score', {'team': 'home', 'points': 1, 'player_id': player['id']}).json()
    assert s['home']['score'] == 14 and s['clock']['running']
    s = initial_state(sport='basketball')
    s, _, _ = apply(s, 'period_start', {}, 0)
    s, _, _ = apply(s, 'clock_start', {}, 0)
    s, event, _ = apply(s, 'score', {'team': 'home', 'points': 2}, 600001)
    assert not s['clock']['running'] and event['points'] == 2


def test_live_basketball_player_statistics_corrections_and_history(system):
    app, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': 8}).json()['slug']
    player = {'id': str(uuid4()), 'number': '7', 'name': 'Alex'}
    kinds = {'rebound': 'reb', 'assist': 'ast', 'steal': 'stl', 'block': 'blk', 'turnover': 'to'}
    def stats(team='home'):
        return control_state(client, slug)[team]['statistics']
    def row(identifier):
        return next(p for p in stats()['players'] if p['id'] == identifier)
    assert stats()['players'][0]['id'] is None
    assert all(value == 0 for value in stats()['totals'].values())
    # Unknown is available before and after a squad is configured.
    command(client, slug, 'rebound', {'team': 'home'})
    command(client, slug, 'squad', {'team': 'home', 'players': [player]})
    command(client, slug, 'score', {'team': 'home', 'points': 2})
    command(client, slug, 'score', {'team': 'home', 'points': 3, 'player_id': player['id']})
    command(client, slug, 'personal_foul', {'team': 'home', 'player_id': player['id']})
    command(client, slug, 'personal_foul', {'team': 'home'})
    # Non-scoring stats can be recorded during play.
    command(client, slug, 'period_start')
    command(client, slug, 'clock_start')
    for kind, column in kinds.items():
        before = control_state(client, slug)
        key = str(uuid4())
        data = {'team': 'home', 'player_id': player['id']}
        s = command(client, slug, kind, data, before, key).json()
        assert command(client, slug, kind, data, before, key).status_code == 200
        event_id = s['events'][-1]['id']
        assert row(player['id'])[column] == 1
        assert command(client, slug, kind + '_correction', {'team': 'away', 'event_id': event_id}).status_code == 422
        corrected = command(client, slug, kind + '_correction', {'team': 'home', 'event_id': event_id}).json()
        assert row(player['id'])[column] == 0
        assert command(client, slug, kind + '_correction', {'team': 'home', 'event_id': event_id}).status_code == 422
        command(client, slug, 'undo', {'event_id': corrected['events'][-1]['id']})
        assert row(player['id'])[column] == 1
        assert command(client, slug, kind, {'team': 'away', 'player_id': player['id']}).status_code == 422
        command(client, slug, kind, {'team': 'home'})
    assert row(None)['pts'] == 2 and row(player['id'])['pts'] == 3
    assert stats()['totals']['pts'] == control_state(client, slug)['home']['score'] == 5
    assert stats()['totals']['pf'] == 2
    assert row(None)['reb'] == 2 and row(player['id'])['reb'] == 1
    assert all(value == 0 for value in stats('away')['totals'].values())
    # Score reassignment updates totals without changing the team score.
    score = next(e for e in control_state(client, slug)['events'] if e['type'] == 'score' and e['player'] is None)
    command(client, slug, 'assign_player', {'team': 'home', 'event_id': score['id'], 'player_id': player['id']})
    assert row(None)['pts'] == 0 and row(player['id'])['pts'] == 5
    command(client, slug, 'score_correction', {'team': 'home', 'event_id': score['id']})
    assert stats()['totals']['pts'] == 3
    command(client, slug, 'squad', {'team': 'home', 'players': [{**player, 'name': 'Alex renamed'}]})
    assert row(player['id'])['name'] == 'Alex renamed'
    command(client, slug, 'squad', {'team': 'home', 'players': []})
    assert row(player['id'])['ast'] == 1
    match_id = control_state(client, slug)['match_id']
    # All seven columns, including PF, stay private.
    public = TestClient(app)
    for endpoint in (f'/api/s/{slug}/state', f'/api/s/{slug}/matches/{match_id}/state'):
        result = public.get(endpoint).json()
        assert 'statistics' not in result['home']
        assert not any(e['type'] in kinds for e in result['events'])
    with public.websocket_connect(f'/ws/s/{slug}') as ws:
        assert 'statistics' not in ws.receive_json()['home']
    command(client, slug, 'game_end')
    command(client, slug, 'new_match')
    assert all(value == 0 for value in stats()['totals'].values())
    archived = client.get(f'/api/s/{slug}/matches/{match_id}/control-state').json()
    assert archived['home']['statistics']['totals']['pts'] == 3
    football = create(client)['slug']
    for kind in kinds:
        assert command(client, football, kind, {'team': 'home'}).status_code == 422


@pytest.mark.parametrize('phase', ['pre_game', 'period_running', 'break'])
def test_delete_planned_and_running_games(system, phase):
    app, client = system
    slug = create(client)['slug']
    if phase != 'pre_game':
        command(client, slug, 'period_start')
    if phase == 'break':
        command(client, slug, 'period_end')
    before = state(client, slug)
    outsider = TestClient(app)
    assert command(outsider, slug, 'delete', current=before).status_code == 401
    key = str(uuid4())
    deleted = command(client, slug, 'delete', current=before, command_id=key)
    assert deleted.status_code == 200
    assert deleted.json()['match_id'] is None
    assert command(client, slug, 'delete', current=before, command_id=key).status_code == 200
    assert client.get('/api/dashboard').json()['boards'][0]['matches'] == []
    assert not any(g['scoreboard'] == slug for g in client.get('/api/live').json()['games'])
    assert client.get(f'/api/s/{slug}/matches/{before["match_id"]}/state').status_code == 410
    assert command(client, slug, 'score', {'team': 'home', 'points': 1}, current=before).status_code == 410
    with client.websocket_connect(f'/ws/s/{slug}') as ws:
        assert ws.receive_json()['match_id'] is None


def test_basketball_period_scores_follow_corrections_and_overtime(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': 2, 'period_length_min': 20}).json()['slug']
    s = command(client, slug, 'score', {'team': 'home', 'points': 1}).json()
    assert s['home']['period_scores'] == [1, 0] and s['away']['period_scores'] == [0, 0]
    command(client, slug, 'period_start')
    s = command(client, slug, 'score', {'team': 'home', 'points': 2}).json()
    command(client, slug, 'period_end')
    command(client, slug, 'period_start')
    q2 = command(client, slug, 'score', {'team': 'away', 'points': 3}).json()
    # Removing the first-period basket during the second period changes the first period only.
    s = command(client, slug, 'score_correction', {'team': 'home', 'event_id': s['events'][-1]['id']}).json()
    assert s['home']['period_scores'] == [1, 0] and s['away']['period_scores'] == [0, 3]
    command(client, slug, 'score', {'team': 'home', 'points': 2})
    command(client, slug, 'period_end')
    command(client, slug, 'overtime_start')
    s = command(client, slug, 'score', {'team': 'away', 'points': 2}).json()
    assert s['home']['period_scores'] == [1, 2, 0] and s['away']['period_scores'] == [0, 3, 2]
    assert state(client, slug)['away']['period_scores'] == [0, 3, 2]
    assert q2['away']['period_scores'] == [0, 3]


def test_create_with_description_and_schedule(system):
    _, client = system
    future = 4102444800000
    created = client.post('/api/scoreboards', json={'sport': 'basketball', 'description': '  U14 Liga · Spieltag 3  ',
                                                     'scheduled_at': future})
    assert created.status_code == 201, created.text
    slug = created.json()['slug']
    private = client.get(f'/api/s/{slug}/control-state').json()
    assert private['description'] == 'U14 Liga · Spieltag 3'
    assert private['scheduled_at'] == future and private['created_at'] <= private['server_now']
    assert private['board_created_at'] == private['created_at']
    public = state(client, slug)
    # The description is public (live directory, viewer); creation details stay private.
    assert public['description'] == 'U14 Liga · Spieltag 3' and 'board_created_at' not in public
    board = client.get('/api/dashboard').json()['boards'][0]
    assert board['description'] == 'U14 Liga · Spieltag 3' and board['matches'][0]['scheduled_at'] == future
    assert client.put(f'/api/s/{slug}/description', json={'description': '   '}).json() == {'description': None}
    assert client.put(f'/api/s/{slug}/description', json={'description': 'x' * 301}).status_code == 422
    assert client.post('/api/scoreboards', json={'scheduled_at': 1000}).status_code == 422
    other = TestClient(client.app)
    assert other.put(f'/api/s/{slug}/description', json={'description': 'hijack'}).status_code in (401, 403)


def test_basketball_technicals_possession_and_lineup(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    ids = [str(uuid4()) for _ in range(7)]
    command(client, slug, 'squad', {'team': 'home', 'players': [{'id': i, 'number': str(n + 4), 'name': ''} for n, i in enumerate(ids)]})
    command(client, slug, 'period_start')
    s = command(client, slug, 'lineup', {'team': 'home', 'player_ids': ids[:5]}).json()
    assert s['home']['on_court'] == ids[:5]
    s = command(client, slug, 'lineup', {'team': 'home', 'player_ids': ids[1:6]}).json()
    sub = s['events'][-1]
    assert [p['id'] for p in sub['entered']] == [ids[5]] and [p['id'] for p in sub['left']] == [ids[0]]
    assert command(client, slug, 'lineup', {'team': 'home', 'player_ids': ids[:6]}).status_code == 422
    assert command(client, slug, 'lineup', {'team': 'home', 'player_ids': [str(uuid4())]}).status_code == 422
    # Player technical: personal + team foul. Coach technical: neither.
    s = command(client, slug, 'technical_foul', {'team': 'home', 'player_id': ids[1]}).json()
    s = command(client, slug, 'technical_foul', {'team': 'home'}).json()
    row = next(p for p in s['home']['statistics']['players'] if p['id'] == ids[1])
    assert row['pf'] == 1 and s['home']['statistics']['totals']['pf'] == 1
    assert s['home']['counters']['team_fouls'] == 1
    s = command(client, slug, 'technical_foul_correction', {'team': 'home', 'event_id': s['events'][-2]['id']}).json()
    assert s['home']['counters']['team_fouls'] == 0
    s = command(client, slug, 'possession', {'team': 'away'}).json()
    assert s['possession'] == 'away'
    s = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
    assert s.get('possession') is None
    public = state(client, slug)
    assert 'on_court' not in public['home']
    assert not any(e['type'] in ('technical_foul', 'lineup') for e in public['events'])
    # Removing a player from the squad also takes them off court.
    s = command(client, slug, 'squad', {'team': 'home', 'players': [{'id': i, 'number': str(n + 4), 'name': ''} for n, i in enumerate(ids) if i != ids[2]]}).json()
    assert ids[2] not in s['home']['on_court']


def test_football_console_events_lineup_and_penalty_goal(system):
    _, client = system
    slug = create(client)['slug']
    ids = [str(uuid4()) for _ in range(13)]
    squad = [{'id': i, 'number': str(n + 1) if n else '', 'name': 'Keeper' if not n else ''} for n, i in enumerate(ids)]
    command(client, slug, 'squad', {'team': 'home', 'players': squad})
    s = command(client, slug, 'lineup', {'team': 'home', 'player_ids': ids[:11]}).json()
    assert s['home']['on_court'] == ids[:11]
    assert command(client, slug, 'lineup', {'team': 'home', 'player_ids': ids[:12]}).status_code == 422
    command(client, slug, 'period_start')
    s = command(client, slug, 'foul', {'team': 'away'}).json()
    s = command(client, slug, 'foul', {'team': 'home', 'player_id': ids[3]}).json()
    assert s['home']['counters']['fouls'] == 1 and s['away']['counters']['fouls'] == 1
    command(client, slug, 'free_kick', {'team': 'home'})
    command(client, slug, 'penalty', {'team': 'home', 'player_id': ids[9]})
    s = command(client, slug, 'score', {'team': 'home', 'points': 1, 'player_id': ids[9], 'detail': 'penalty'}).json()
    assert s['home']['score'] == 1 and s['events'][-1]['detail'] == 'penalty'
    assert command(client, slug, 'score', {'team': 'home', 'points': 1, 'detail': 'bicycle'}).status_code == 422
    s = command(client, slug, 'foul_correction', {'team': 'home', 'event_id': s['events'][-4]['id']}).json()
    assert s['home']['counters']['fouls'] == 0
    assert command(client, slug, 'rebound', {'team': 'home'}).status_code == 422
    public = state(client, slug)
    assert not any(e['type'] in ('foul', 'free_kick', 'penalty', 'lineup') for e in public['events'])
    assert public['events'][-1]['detail'] == 'penalty'
    b = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    assert command(client, b, 'foul', {'team': 'home'}).status_code == 422



def test_cleaner_trashes_abandoned_and_unstarted_games_and_purges(system):
    app, client = system
    hour = 3600
    running = create(client)['slug']
    command(client, running, 'period_start')
    finished = create(client)['slug']
    command(client, finished, 'period_start')
    command(client, finished, 'game_end')
    fresh = create(client)['slug']
    scheduled = client.post('/api/scoreboards', json={'scheduled_at': 4102444800000}).json()['slug']
    t0 = __import__('time').time()
    with app.state.sessions() as db:
        assert clean_matches(db, t0 + 23 * hour) == (0, 0)
    with app.state.sessions() as db:
        assert clean_matches(db, t0 + 25 * hour) == (1, 0)          # abandoned running game
    gone = state(client, running)
    assert gone['phase'] == 'no_match'                               # removed from stream/controller
    game = next(g for b in client.get('/api/dashboard').json()['boards'] if b['slug'] == running for g in b['matches'])
    assert game['trashed'] and game['trash_reason'] == 'abandoned'
    with app.state.sessions() as db:
        assert clean_matches(db, t0 + 7 * 24 * hour + hour) == (1, 0)  # never-used board, no start time
    assert state(client, fresh)['phase'] == 'no_match'
    assert state(client, finished)['phase'] == 'finished'            # finished games are never trashed
    assert state(client, scheduled)['phase'] == 'pre_game'           # start time still in the future
    # Restore counts as activity, so the cleaner does not trash it again at once.
    m = game['match_id']
    restored = client.post(f'/api/s/{running}/matches/{m}/commands', json={
        'command_id': str(uuid4()), 'expected_revision': game['revision'], 'action': 'restore', 'data': {}})
    assert restored.status_code == 200, restored.text
    assert command(client, running, 'activate', current=client.get(f'/api/s/{running}/matches/{m}/state').json()).status_code == 200
    with app.state.sessions() as db:
        assert clean_matches(db, __import__('time').time() + hour) == (0, 0)
    # Trash older than the retention period is deleted permanently; the
    # restored game is abandoned again after another quiet day.
    with app.state.sessions() as db:
        assert clean_matches(db, t0 + 40 * 24 * hour) == (1, 1)
    boards = client.get('/api/dashboard').json()['boards']
    assert not any(g['match_id'] for b in boards if b['slug'] == fresh for g in b['matches'])


def test_private_board_hides_spectators_but_keeps_controllers_and_obs(system):
    _, client = system
    slug = create(client)['slug']
    private = client.get(f'/api/s/{slug}/control-state').json()
    key = private['overlay_key']
    assert key and private['private'] is False
    command(client, slug, 'period_start')
    stranger = TestClient(client.app)
    assert stranger.get(f'/api/s/{slug}/state').status_code == 200
    assert any(g['scoreboard'] == slug for g in stranger.get('/api/live').json()['games'])
    assert client.put(f'/api/s/{slug}/privacy', json={'private': True}).json() == {'private': True}
    assert stranger.put(f'/api/s/{slug}/privacy', json={'private': False}).status_code == 401
    assert stranger.get(f'/api/s/{slug}/state').status_code == 403
    assert 'Privates Spiel' in stranger.get(f'/s/{slug}').text
    assert not any(g['scoreboard'] == slug for g in stranger.get('/api/live').json()['games'])
    with pytest.raises(Exception):
        with stranger.websocket_connect(f'/ws/s/{slug}') as ws:
            ws.receive_json()
    # Controllers and the OBS overlay (with its key) keep working.
    assert client.get(f'/api/s/{slug}/state').status_code == 200
    assert stranger.get(f'/api/s/{slug}/state?k={key}').status_code == 200
    assert stranger.get(f'/api/s/{slug}/state?k=wrong').status_code == 403
    assert 'Privates Spiel' not in stranger.get(f'/s/{slug}/overlay?k={key}').text
    with stranger.websocket_connect(f'/ws/s/{slug}?k={key}') as ws:
        assert ws.receive_json()['scoreboard'] == slug
    client.put(f'/api/s/{slug}/privacy', json={'private': False})
    assert stranger.get(f'/api/s/{slug}/state').status_code == 200


def test_football_formats_up_to_ninety_minute_periods(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'period_count': 1, 'period_length_min': 90}).json()['slug']
    s = state(client, slug)
    assert (s['period_count'], s['period_length_min']) == (1, 90)
    assert client.post('/api/scoreboards', json={'period_length_min': 121}).status_code == 422


def test_basketball_free_throws_made_and_missed(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    pid = str(uuid4())
    command(client, slug, 'squad', {'team': 'home', 'players': [{'id': pid, 'number': '7', 'name': ''}]})
    command(client, slug, 'score', {'team': 'home', 'points': 1, 'player_id': pid, 'detail': 'free_throw'})
    command(client, slug, 'free_throw_missed', {'team': 'home', 'player_id': pid})
    s = command(client, slug, 'score', {'team': 'home', 'points': 1, 'detail': 'free_throw'}).json()
    row = next(p for p in s['home']['statistics']['players'] if p['id'] == pid)
    assert (row['pts'], row['ftm'], row['ftx']) == (1, 1, 1)
    assert s['home']['score'] == 2 and s['home']['statistics']['totals']['ftm'] == 2
    assert command(client, slug, 'score', {'team': 'home', 'points': 2, 'detail': 'free_throw'}).status_code == 422
    assert command(client, slug, 'score', {'team': 'home', 'points': 1, 'detail': 'penalty'}).status_code == 422
    assert not any(e['type'] == 'free_throw_missed' for e in state(client, slug)['events'])


def test_admin_score_adjustment_is_logged_and_undoable(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 3})
    s = command(client, slug, 'score_adjust', {'team': 'home', 'delta': -1}).json()
    assert s['home']['score'] == 2 and s['home']['period_scores'][0] == 2
    assert s['events'][-1]['type'] == 'score_adjust' and s['events'][-1]['points'] == -1
    assert state(client, slug)['events'][-1]['type'] == 'score_adjust'   # visible to spectators
    s = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
    assert s['home']['score'] == 3
    for bad in ({'team': 'home', 'delta': 0}, {'team': 'home', 'delta': 1.5}, {'team': 'x', 'delta': 1}):
        assert command(client, slug, 'score_adjust', bad).status_code == 422


def test_ending_last_basketball_period_ends_the_match_unless_tied(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': 2, 'period_length_min': 5}).json()['slug']
    command(client, slug, 'period_start')
    s = command(client, slug, 'period_end').json()
    assert s['phase'] == 'break'                          # not the last period
    command(client, slug, 'period_start')
    s = command(client, slug, 'period_end').json()
    assert s['phase'] == 'break'                          # tied 0:0 -> overtime offered
    command(client, slug, 'overtime_start')
    command(client, slug, 'score', {'team': 'away', 'points': 2})
    s = command(client, slug, 'period_end').json()
    assert s['phase'] == 'finished' and s['events'][-1]['type'] == 'game_end' and s['events'][-1]['automatic']
    s = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
    assert s['phase'] == 'break'


def test_display_pairing_assignment_and_device_feed(system):
    _, client = system
    slug = create(client)['slug']
    command(client, slug, 'period_start')
    created = client.post('/api/displays', json={'name': 'Halle 1'})
    assert created.status_code == 201
    display = created.json()
    assert len(display['code']) == 6 and not display['paired'] and display['board'] is None
    listed = client.get('/api/displays').json()['displays']
    assert [d['id'] for d in listed] == [display['id']]
    # Assigning needs control of the board; strangers cannot manage the display.
    stranger = TestClient(client.app)
    assert stranger.get('/api/displays').json()['displays'] == []
    assert stranger.put(f"/api/displays/{display['id']}", json={'name': 'x'}).status_code == 404
    other = stranger.post('/api/scoreboards', json={}).json()['slug']
    assert client.put(f"/api/displays/{display['id']}", json={'board': other}).status_code == 401
    assert client.put(f"/api/displays/{display['id']}", json={'board': slug}).json()['board'] == slug
    # Device pairing with the code (case and dashes ignored), once.
    device = TestClient(client.app)
    assert device.post('/api/display/pair', json={'code': 'ZZZZZZ'}).status_code == 404
    paired = device.post('/api/display/pair', json={'code': display['code'].lower()[:3] + '-' + display['code'][3:]})
    assert paired.status_code == 200
    token = paired.json()['token']
    assert device.post('/api/display/pair', json={'code': display['code']}).status_code == 404
    headers = {'Authorization': f'Bearer {token}'}
    feed = device.get('/api/display/state', headers=headers).json()
    assert feed['board'] == slug and feed['state']['phase'] == 'period_running'
    assert device.get('/api/display/state').status_code == 401
    # Private boards stay visible to their paired display.
    client.put(f'/api/s/{slug}/privacy', json={'private': True})
    assert device.get('/api/display/state', headers=headers).json()['state']['scoreboard'] == slug
    with device.websocket_connect(f'/ws/display?token={token}') as ws:
        assert ws.receive_json()['board'] == slug
        command(client, slug, 'score', {'team': 'home', 'points': 1})
        assert ws.receive_json()['state']['home']['score'] == 1
    info = client.get('/api/displays').json()['displays'][0]
    assert info['paired'] and info['online'] and info['code'] is None
    # Unassign, then remove: the device token stops working.
    assert client.put(f"/api/displays/{display['id']}", json={'board': None}).json()['board'] is None
    assert device.get('/api/display/state', headers=headers).json()['state'] is None
    renewed = client.post(f"/api/displays/{display['id']}/code", json={}).json()
    assert renewed['code'] and renewed['code'] != display['code']
    assert client.delete(f"/api/displays/{display['id']}").json() == {'ok': True}
    assert device.get('/api/display/state', headers=headers).status_code == 401


def test_live_lists_upcoming_games_in_the_next_days(system):
    _, client = system
    import time as clock
    soon = round((clock.time() + 5 * 3600) * 1000)
    later = round((clock.time() + 5 * 86400) * 1000)
    a = client.post('/api/scoreboards', json={'sport': 'basketball', 'scheduled_at': soon}).json()['slug']
    b = client.post('/api/scoreboards', json={'scheduled_at': later}).json()['slug']
    hidden = client.post('/api/scoreboards', json={'scheduled_at': soon}).json()['slug']
    client.put(f'/api/s/{hidden}/privacy', json={'private': True})
    running = create(client)['slug']
    command(client, running, 'period_start')
    live = TestClient(client.app).get('/api/live').json()
    assert [g['scoreboard'] for g in live['games']] == [running]
    upcoming = live['upcoming']
    assert [g['scoreboard'] for g in upcoming] == [a]                      # 5 days away and private are excluded
    assert upcoming[0]['scheduled_at'] == soon and upcoming[0]['active'] and upcoming[0]['sport'] == 'basketball'
    assert upcoming[0]['description'] is None and 'score' not in upcoming[0]['home']
    assert b



def test_livestream_link_is_public_and_https_only(system):
    _, client = system
    created = client.post('/api/scoreboards', json={'description': 'Derby', 'stream_url': ' https://youtube.com/live/abc '})
    slug = created.json()['slug']
    command(client, slug, 'period_start')
    viewer = TestClient(client.app)
    public = viewer.get(f'/api/s/{slug}/state').json()
    assert public['stream_url'] == 'https://youtube.com/live/abc' and public['description'] == 'Derby'
    game = viewer.get('/api/live').json()['games'][0]
    assert game['stream_url'] == 'https://youtube.com/live/abc' and game['description'] == 'Derby'
    for bad in ('javascript:alert(1)', 'http://insecure.example', 'https://', 'https://x.y/a b', 'ftp://x.y'):
        assert client.put(f'/api/s/{slug}/stream', json={'stream_url': bad}).status_code == 422, bad
        assert client.post('/api/scoreboards', json={'stream_url': bad}).status_code == 422, bad
    assert client.put(f'/api/s/{slug}/stream', json={'stream_url': 'https://fb.watch/xyz'}).json() == {'stream_url': 'https://fb.watch/xyz'}
    assert viewer.put(f'/api/s/{slug}/stream', json={'stream_url': None}).status_code == 401
    assert client.put(f'/api/s/{slug}/stream', json={'stream_url': '  '}).json() == {'stream_url': None}


def _png(width=600, height=400, color=(200, 16, 46, 255)):
    import base64, io
    from PIL import Image
    out = io.BytesIO()
    Image.new('RGBA', (width, height), color).save(out, 'PNG')
    return 'data:image/png;base64,' + base64.b64encode(out.getvalue()).decode()


def test_team_logo_upload_reencodes_and_is_public(system):
    _, client = system
    slug = create(client)['slug']
    match = state(client, slug)['match_id']
    url = f'/api/s/{slug}/matches/{match}/logo'
    s = client.post(url, json={'team': 'home', 'data': _png()}).json()
    logo = s['home']['logo']
    assert logo.startswith('/media/') and logo.endswith('.png')
    media = TestClient(client.app).get(logo)
    assert media.status_code == 200 and media.headers['content-type'] == 'image/png'
    from PIL import Image
    import io
    assert max(Image.open(io.BytesIO(media.content)).size) == 256          # downscaled, re-encoded
    assert state(client, slug)['home']['logo'] == logo                     # public
    # Garbage, wrong types, svg and bombs are rejected; strangers cannot upload.
    for bad in ('data:image/png;base64,AAAA', 'data:image/svg+xml;base64,PHN2Zz4=', 'not-a-data-url', _png(2500, 2000)):
        assert client.post(url, json={'team': 'away', 'data': bad}).status_code == 422
    assert TestClient(client.app).post(url, json={'team': 'away', 'data': _png()}).status_code == 401
    assert client.post(url, json={'team': 'away', 'data': 'x' * 500_000}).status_code in (413, 422)
    # Only stored logos can be referenced through settings; removal works.
    assert command(client, slug, 'settings', {'home': {'logo': 'https://evil.example/x.png'}}).status_code == 422
    assert client.post(url, json={'team': 'home', 'data': None}).json()['home']['logo'] is None
    assert TestClient(client.app).get('/media/' + '0' * 32 + '.png').status_code == 404
