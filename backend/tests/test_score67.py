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

from score67.app import create_app, clean_matches, finish_overdue_matches
from score67.db import Admin, Board, MatchEvent, Base
from score67.domain import RuleError, apply, elapsed, initial_state


@pytest.fixture
def system(tmp_path, monkeypatch, request):
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
    # Existing scenarios deliberately seed multiple legacy boards. Policy tests
    # opt into the production default via indirect parametrization below.
    app = create_app(url, secure_cookies=False, single_active_board=getattr(request, 'param', False))
    with TestClient(app) as client:
        yield app, client


def create(client):
    r = client.post('/api/scoreboards', json={})
    assert r.status_code == 201, r.text
    return r.json()


def test_homepage_quickstart_uses_standard_sports_and_opens_control(system):
    _, client = system
    for lang, label in [('de', 'Schnellstart'), ('en', 'Quickstart')]:
        homepage = client.get('/' + ('?lang=en' if lang == 'en' else ''))
        assert homepage.status_code == 200
        assert f'id="quickstart-toggle"' in homepage.text
        assert label in homepage.text
        assert homepage.text.index('id="quickstart-toggle"') < homepage.text.index('class="landing-actions"')
        assert 'href="/settings"' in homepage.text
        assert 'href="/anzeigetafel/led-bauanleitung"' in homepage.text
        assert '/static/site.mjs?v=' in homepage.text
        assert '/static/site.css?v=' in homepage.text
        assert homepage.headers['cache-control'] == 'no-store'

    for sport, periods, minutes, lineup in [('football', 2, 45, 11), ('basketball', 4, 10, 5)]:
        response = client.post('/api/scoreboards', json={'sport': sport, 'language': 'de'})
        assert response.status_code == 201
        result = response.json()
        game = state(client, result['slug'])
        assert (game['sport'], game['period_count'], game['period_length_min'], game['lineup_size']) == (
            sport, periods, minutes, lineup)
        assert game['phase'] == 'pre_game'
        assert result['links']['control'] == f"/s/{result['slug']}/control"
        assert client.get(f"/api/s/{result['slug']}/control-state").status_code == 200


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
    assert outsider.get('/api/dashboard').json() == {'boards': [], 'account': None, 'device': {'browsers': 0}}
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
    assert set(games[running]) == {'sport', 'team_fouls_enabled', 'overtime_length_min', 'scoreboard', 'match_id', 'home', 'away', 'clock', 'phase', 'period', 'period_count', 'period_length_min', 'server_now', 'location', 'description', 'stream_url', 'creator', 'shootout'}
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
    assert state(client, slug)['home']['counters']['red_cards'] == 1   # Alice's second yellow: yellow-red
    assert command(client, slug, 'red_card', {'team': 'home', 'player_id': alice['id']}).json()['events'][-1]['player'] == alice
    command(client, slug, 'squad', {'team': 'home', 'players': [{**bob, 'name': 'Renamed'}]})
    assert next(e for e in state(client, slug)['events'] if e['id'] == goal['id'])['player']['name'] == 'Alice'
    removed = command(client, slug, 'score_correction', {'team': 'home', 'points': -1, 'event_id': goal['id']}).json()
    assert removed['home']['score'] == 0 and removed['events'][-1]['player'] == alice
    old = removed['match_id']
    command(client, slug, 'game_end')
    fresh = command(client, slug, 'new_match').json()
    # A new game keeps the teams (squad included) but starts with clean counters.
    assert [p['number'] for p in fresh['home']['squad']] == ['10'] and fresh['home']['counters']['yellow_cards'] == 0
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
    assert client.put(f'/api/s/{slug}/description', json={'description': '   '}).json() == {'description': None, 'creator': None}
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



def test_cleaner_preserves_unstarted_games_and_trashes_abandoned_games(system):
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
    with app.state.sessions() as db:
        assert clean_matches(db, t0 + 29 * 24 * hour) == (0, 0)          # an unstarted board survives four weeks
    gone = state(client, running)
    assert gone['phase'] == 'no_match'                               # removed from stream/controller
    game = next(g for b in client.get('/api/dashboard').json()['boards'] if b['slug'] == running for g in b['matches'])
    assert game['trashed'] and game['trash_reason'] == 'abandoned'
    with app.state.sessions() as db:
        assert clean_matches(db, t0 + 7 * 24 * hour + hour) == (0, 0)  # preparation does not expire
    assert state(client, fresh)['phase'] == 'pre_game'
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
        assert clean_matches(db, t0 + 40 * 24 * hour) == (1, 0)
    boards = client.get('/api/dashboard').json()['boards']
    assert any(g['match_id'] for b in boards if b['slug'] == fresh for g in b['matches'])
    with app.state.sessions() as db:
        assert clean_matches(db, 4102444800 + 40 * 86400) == (0, 1)
    assert state(client, scheduled)['phase'] == 'pre_game'


def test_overdue_games_end_automatically(system):
    app, client = system
    minute = 60
    football = create(client)['slug']                                # 2×45 → ends 180 min after kickoff
    command(client, football, 'period_start')
    command(client, football, 'score', {'team': 'home', 'points': 1})
    unstarted = create(client)['slug']
    done = create(client)['slug']
    command(client, done, 'period_start')
    command(client, done, 'game_end')
    t0 = __import__('time').time()
    with app.state.sessions() as db:
        assert finish_overdue_matches(db, t0 + 179 * minute) == 0
        # An entry 10 min ago (e.g. extra time) postpones the end.
        last = db.scalar(select(MatchEvent).order_by(MatchEvent.id.desc()).where(MatchEvent.payload['type'].as_string() == 'score'))
        last.payload = {**last.payload, 'occurred_at': (t0 + 171 * minute) * 1000}
        db.commit()
        assert finish_overdue_matches(db, t0 + 181 * minute) == 0
        assert finish_overdue_matches(db, t0 + 187 * minute) == 1
        assert finish_overdue_matches(db, t0 + 400 * minute) == 0      # only once
    s = state(client, football)
    assert s['phase'] == 'finished' and s['home']['score'] == 1
    assert s['clock']['elapsed_ms'] == 45 * 60000 and not s['clock']['running']   # frozen at 45:00
    assert state(client, unstarted)['phase'] == 'pre_game'
    assert state(client, done)['phase'] == 'finished'
    # The controller can undo the automatic end.
    with app.state.sessions() as db:
        end = db.scalar(select(MatchEvent).order_by(MatchEvent.id.desc()))
        assert end.payload['type'] == 'game_end' and end.payload['automatic']
        end_id = end.id
    assert command(client, football, 'undo', {'event_id': end_id}).json()['phase'] == 'period_running'
    # Reopened for corrections: it stays open until it has been quiet again.
    from score67.db import Match
    with app.state.sessions() as db:
        reopened = db.scalar(select(Match).where(Match.slug == football))
        assert reopened.touched_at >= t0                              # the undo counts as activity
        reopened.touched_at = t0 + 190 * minute                       # as if undone 190 min after kickoff
        db.commit()
        assert finish_overdue_matches(db, t0 + 195 * minute) == 0
        assert finish_overdue_matches(db, t0 + 206 * minute) == 1


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
    assert s['phase'] == 'finished' and s['events'][-1]['type'] == 'game_end' and s['events'][-1]['decided']
    s = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
    assert s['phase'] == 'break'


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


def test_email_login_restores_boards_on_a_new_device(system, monkeypatch):
    app, client = system
    monkeypatch.setenv('MAIL_LOG', 'true')
    sent = []
    app.state.send_mail = lambda to, subject, body: sent.append((to, body))

    def sign_in(c, email):
        assert c.post('/api/account/login', json={'email': email}).status_code == 200
        token = sent[-1][1].split('#t=')[1].split()[0]
        return c.post('/api/account/verify', json={'token': token})

    slug = create(client)['slug']
    assert client.get('/api/account').json() == {'mail_enabled': True, 'email': None}
    # Signing in on the old phone links the boards it controls.
    r = sign_in(client, ' Coach@Example.org ')
    assert r.status_code == 200 and r.json() == {'email': 'coach@example.org', 'linked': 1}
    assert sent[-1][0] == 'coach@example.org'
    owner = client.get(f'/api/s/{slug}/owner').json()
    assert owner == {'email': 'coach@example.org', 'mine': True, 'signed_in': 'coach@example.org'}
    # The link works only once.
    token = sent[-1][1].split('#t=')[1].split()[0]
    assert client.post('/api/account/verify', json={'token': token}).status_code == 401
    # New phone: no board cookie, nothing to control until signed in.
    phone = TestClient(app)
    assert phone.get('/api/dashboard').json()['boards'] == []
    assert phone.get(f'/api/s/{slug}/control-state').status_code == 401
    assert sign_in(phone, 'coach@example.org').json()['linked'] == 0
    boards = phone.get('/api/dashboard').json()
    assert boards['account'] == {'email': 'coach@example.org'}
    assert [b['slug'] for b in boards['boards']] == [slug] and boards['boards'][0]['owned']
    s = phone.get(f'/api/s/{slug}/control-state').json()
    r = phone.post(f'/api/s/{slug}/matches/{s["match_id"]}/commands', json={
        'command_id': str(uuid4()), 'expected_revision': s['revision'], 'action': 'period_start', 'data': {}})
    assert r.status_code == 200, r.text
    # Boards created while signed in belong to the account at once.
    own = phone.post('/api/scoreboards', json={}).json()['slug']
    assert phone.get(f'/api/s/{own}/owner').json()['mine']
    # A different person sees a masked address and cannot take over the board.
    stranger = TestClient(app)
    pin = client.post(f'/api/s/{slug}/pin', json={}).json()['pin']
    assert stranger.post(f'/api/s/{slug}/admin/claim', json={'pin': pin}).status_code == 200
    assert stranger.get(f'/api/s/{slug}/owner').json()['email'] == 'co•••@example.org'
    sign_in(stranger, 'other@example.org')
    assert stranger.put(f'/api/s/{slug}/owner', json={'linked': True}).status_code == 409
    # Unlinking by someone else notifies the owner; then the email no longer gives access.
    assert stranger.put(f'/api/s/{slug}/owner', json={'linked': False}).status_code == 200
    assert sent[-1][0] == 'coach@example.org'
    phone.cookies.clear()
    sign_in(phone, 'coach@example.org')
    assert [b['slug'] for b in phone.get('/api/dashboard').json()['boards']] == [own]
    # Logout ends the session.
    assert phone.post('/api/account/logout', json={}).status_code == 200
    assert phone.get('/api/account').json()['email'] is None


def test_email_login_rules(system, monkeypatch):
    app, client = system
    sent = []
    app.state.send_mail = lambda to, subject, body: sent.append(to)
    assert client.post('/api/account/login', json={'email': 'a@b.de'}).json()['error'] == 'mail_disabled'
    monkeypatch.setenv('MAIL_LOG', 'true')
    assert client.post('/api/account/login', json={'email': 'not-an-email'}).status_code == 422
    for _ in range(5):
        assert client.post('/api/account/login', json={'email': 'a@b.de'}).status_code == 200
    assert client.post('/api/account/login', json={'email': 'a@b.de'}).status_code == 429
    assert len(sent) == 5
    assert client.post('/api/account/verify', json={'token': 'x' * 40}).status_code == 401


def test_forum_code_publishes_and_signs_in(system, monkeypatch):
    app, client = system
    monkeypatch.setenv('MAIL_LOG', 'true')
    monkeypatch.setenv('FORUM_MODERATOR_EMAIL', 'mod@example.org')
    sent = []
    app.state.send_mail = lambda to, subject, body: sent.append((to, subject, body))
    assert client.get('/api/forum').json() == {'threads': []}
    assert client.get('/api/forum/me').json() == {'mail_enabled': True, 'email': None}
    # A new topic needs a subject; the address must look like one.
    assert client.post('/api/forum/posts', json={'body': 'Hi', 'name': 'Carla', 'email': 'c@example.org'}).status_code == 422
    assert client.post('/api/forum/posts', json={'title': 'T', 'body': 'Hi', 'name': 'Carla', 'email': 'nope'}).status_code == 422
    r = client.post('/api/forum/posts', json={'title': 'Wish: shot clock', 'body': 'Please add\na shot clock', 'name': 'Carla',
                                              'email': 'Carla@Example.org', 'language': 'en'})
    assert r.status_code == 200 and r.json()['pending']
    post_id = r.json()['post_id']
    to, subject, body = sent.pop()
    code = next(line for line in body.splitlines() if line.strip().isdigit()).strip()
    assert to == 'carla@example.org' and 'forum' in subject.lower() and len(code) == 6
    # Unconfirmed posts are invisible.
    assert client.get('/api/forum').json()['threads'] == []
    wrong = '000000' if code != '000000' else '111111'
    assert client.post(f'/api/forum/posts/{post_id}/verify', json={'code': wrong}).status_code == 401
    r = client.post(f'/api/forum/posts/{post_id}/verify', json={'code': code})
    assert r.status_code == 200 and r.json()['thread_id'] == post_id
    assert client.post(f'/api/forum/posts/{post_id}/verify', json={'code': code}).status_code == 404
    threads = client.get('/api/forum').json()['threads']
    assert [(t['title'], t['author'], t['replies']) for t in threads] == [('Wish: shot clock', 'Carla', 0)]
    assert 'email' not in threads[0] and 'Example' not in str(client.get(f'/api/forum/{post_id}').json())
    # The moderator got the post with a hide link.
    to, subject, body = sent.pop()
    assert to == 'mod@example.org' and 'carla@example.org' in body
    key = body.split('#k=')[1].strip()
    # The code signed this browser in: the reply is published at once, no code.
    assert client.get('/api/forum/me').json()['email'] == 'carla@example.org'
    r = client.post('/api/forum/posts', json={'thread_id': post_id, 'body': 'Me too', 'name': 'Carla'})
    assert r.json()['published'] and r.json()['thread_id'] == post_id
    sent.clear()
    page = client.get(f'/api/forum/{post_id}').json()
    assert page['thread']['body'] == 'Please add\na shot clock' and [p['body'] for p in page['replies']] == ['Me too']
    assert client.get('/api/forum').json()['threads'][0]['replies'] == 1
    # Replies only to existing topics, not to replies.
    assert client.post('/api/forum/posts', json={'thread_id': page['replies'][0]['id'], 'body': 'x', 'name': 'C'}).status_code == 404
    # Moderation: the key from the mail hides the topic; a wrong key does nothing.
    assert client.post(f'/api/forum/posts/{post_id}/moderate', json={'key': 'x' * 20}).status_code == 403
    assert client.post(f'/api/forum/posts/{post_id}/moderate', json={'key': key}).json()['hidden']
    assert client.get('/api/forum').json()['threads'] == []
    assert client.get(f'/api/forum/{post_id}').status_code == 404
    assert not client.post(f'/api/forum/posts/{post_id}/moderate', json={'key': key, 'hidden': False}).json()['hidden']
    for path in ('/forum', f'/forum/{post_id}', '/about', '/features', '/', f'/forum/moderate/{post_id}'):
        assert client.get(path).status_code == 200, path


def test_forum_codes_expire_lock_and_bots_are_ignored(system, monkeypatch):
    app, client = system
    sent = []
    app.state.send_mail = lambda to, subject, body: sent.append(body)
    # Without mail delivery nobody can confirm an address.
    monkeypatch.delenv('SMTP_HOST', raising=False)
    monkeypatch.setenv('MAIL_LOG', 'false')
    new = {'title': 'T', 'body': 'B', 'name': 'N', 'email': 'n@example.org'}
    assert client.post('/api/forum/posts', json=new).status_code == 503
    monkeypatch.setenv('MAIL_LOG', 'true')
    # The honeypot field: answered like a success, nothing stored or sent.
    assert client.post('/api/forum/posts', json={**new, 'website': 'http://spam'}).json() == {'pending': True, 'post_id': 0}
    assert sent == []
    post_id = client.post('/api/forum/posts', json=new).json()['post_id']
    for _ in range(5):
        assert client.post(f'/api/forum/posts/{post_id}/verify', json={'code': '99999a'}).status_code == 401
    assert client.post(f'/api/forum/posts/{post_id}/verify', json={'code': '99999a'}).status_code == 429
    post_id = client.post('/api/forum/posts', json=new).json()['post_id']
    code = next(line for line in sent[-1].splitlines() if line.strip().isdigit()).strip()
    import score67.forum as forum
    monkeypatch.setattr(forum.time, 'time', lambda: 4_000_000_000.0)
    assert client.post(f'/api/forum/posts/{post_id}/verify', json={'code': code}).status_code == 410
    # Five codes per address and hour.
    monkeypatch.undo()
    monkeypatch.setenv('MAIL_LOG', 'true')
    codes = [client.post('/api/forum/posts', json=new).status_code for _ in range(5)]
    assert codes[-1] == 429


def test_players_on_court_setting(system):
    app, client = system
    r = client.post('/api/scoreboards', json={'sport': 'basketball', 'lineup_size': 4})
    slug = r.json()['slug']
    s = state(client, slug)
    assert s['lineup_size'] == 4
    players = [{'id': str(uuid4()), 'number': str(n), 'name': ''} for n in range(4, 11)]
    assert command(client, slug, 'squad', {'team': 'home', 'players': players}).status_code == 200
    ids = [p['id'] for p in players]
    assert command(client, slug, 'lineup', {'team': 'home', 'player_ids': ids[:5]}).status_code == 422
    assert command(client, slug, 'lineup', {'team': 'home', 'player_ids': ids[:4]}).status_code == 200
    # Shrinking below the players on court is refused; growing up to the sport's maximum works.
    assert command(client, slug, 'settings', {'lineup_size': 3}).json()['error'] == 'lineup_too_large'
    assert command(client, slug, 'settings', {'lineup_size': 6}).status_code == 422
    assert command(client, slug, 'settings', {'lineup_size': 5}).json()['lineup_size'] == 5
    assert command(client, slug, 'lineup', {'team': 'home', 'player_ids': ids[:5]}).status_code == 200
    # Default: the sport's maximum; a too large value at creation is capped.
    assert state(client, create(client)['slug'])['lineup_size'] == 11
    big = client.post('/api/scoreboards', json={'sport': 'basketball', 'lineup_size': 11}).json()['slug']
    assert state(client, big)['lineup_size'] == 5


def test_link_previews_for_whatsapp_and_facebook(system):
    import re as regex
    app, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'description': 'U12 Liga'}).json()['slug']
    command(client, slug, 'settings', {'home': {'name': 'Bramfeld'}, 'away': {'name': 'Scaletta'}})
    page = client.get(f'/s/{slug}').text
    tags = dict(regex.findall(r'<meta property="(og:[a-z:]+)" content="([^"]*)"', page))
    assert tags['og:title'].startswith('Bramfeld – Scaletta')
    assert 'U12 Liga' in tags['og:description'] and 'Basketball' in tags['og:description']
    assert tags['og:image'].startswith('http') and f'/s/{slug}/preview.png' in tags['og:image']
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 3})
    page = client.get(f'/s/{slug}').text
    assert 'Bramfeld 3 : 0 Scaletta · LIVE' in page and '<title>Bramfeld 3 : 0 Scaletta · LIVE</title>' in page
    image = client.get(tags['og:image'].split('testserver')[-1])
    assert image.status_code == 200 and image.headers['content-type'] == 'image/png' and image.content[:4] == b'\x89PNG'
    assert client.get('/preview.png').content[:4] == b'\x89PNG'
    # The OBS overlay needs no tags; site pages get the generic card.
    assert 'og:title' not in client.get(f'/s/{slug}/overlay').text
    assert '/preview.png' in client.get('/').text and '/preview.png' in client.get('/forum').text


def test_live_list_keeps_just_finished_games(system, monkeypatch):
    app, client = system
    slug = create(client)['slug']
    command(client, slug, 'settings', {'home': {'name': 'Bramfeld'}, 'away': {'name': 'Scaletta'}})
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 1})
    live = client.get('/api/live').json()
    assert [g['scoreboard'] for g in live['games']] == [slug] and live['finished'] == []
    command(client, slug, 'game_end')
    live = client.get('/api/live').json()
    assert live['games'] == []
    [game] = live['finished']
    assert game['home']['name'] == 'Bramfeld' and game['home']['score'] == 1 and not game['automatic']
    # After the window the game leaves the list.
    monkeypatch.setenv('LIVE_FINISHED_HOURS', '0')
    assert client.get('/api/live').json()['finished'] == []


def test_impressum_and_datenschutz_are_linked_everywhere(system):
    import json as _json
    app, client = system
    legal = _json.loads((Path(__file__).parents[2] / 'shared/legal.json').read_text())
    for path in ('/impressum', '/datenschutz'):
        page = client.get(path)
        assert page.status_code == 200 and legal['email'] in page.text
    assert 'Hetzner Online GmbH' in client.get('/datenschutz').text
    slug = create(client)['slug']
    for path in ('/', '/about', '/features', '/forum', '/live', f'/s/{slug}'):
        text = client.get(path).text
        assert 'href="/impressum"' in text and 'href="/datenschutz"' in text, path


def test_restart_keeps_teams_and_never_replaces_a_running_game(system):
    app, client = system
    slug = create(client)['slug']
    players = [{'id': str(uuid4()), 'number': '7', 'name': 'Ali'}]
    command(client, slug, 'squad', {'team': 'home', 'players': players})
    command(client, slug, 'settings', {'home': {'name': 'Bramfeld', 'color': '#16a34a'}, 'away': {'name': 'Scaletta'}})
    command(client, slug, 'lineup', {'team': 'home', 'player_ids': [players[0]['id']]})
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 1})
    command(client, slug, 'game_end')
    finished = state(client, slug)
    s = command(client, slug, 'new_match').json()
    assert s['match_id'] != finished['match_id'] and s['phase'] == 'pre_game'
    assert (s['home']['name'], s['home']['color'], s['away']['name']) == ('Bramfeld', '#16a34a', 'Scaletta')
    assert s['home']['squad'] == finished['home']['squad'] and s['home']['score'] == 0
    assert not s['home'].get('on_court')
    # The new game runs; restarting the old finished one must not replace it.
    command(client, slug, 'period_start')
    old = client.get(f'/api/s/{slug}/matches/{finished["match_id"]}/state').json()
    r = client.post(f'/api/s/{slug}/matches/{finished["match_id"]}/commands', json={
        'command_id': str(uuid4()), 'expected_revision': old['revision'], 'action': 'new_match', 'data': {}})
    assert r.status_code == 409 and r.json()['error'] == 'game_running'


def test_viewer_offers_controller_only_to_controllers(system):
    app, client = system
    slug = create(client)['slug']
    page = client.get(f'/s/{slug}').text
    assert 'id="controller-button"' in page and 'data-i18n="control"' in page
    stranger = TestClient(app)
    page = stranger.get(f'/s/{slug}').text
    assert 'id="controller-button"' not in page and 'data-i18n="share.take_control"' in page


def test_pages_are_readable_without_javascript_and_listed_for_search(system):
    import re as regex
    app, client = system
    landing = client.get('/').text
    assert regex.search(r'<h1 data-i18n="landing.title">[^<]+</h1>', landing), 'texts are rendered on the server'
    assert '<title>Score67 – Live-Spielstand' in landing and 'data-server-lang="de"' in landing
    assert '<link rel="canonical" href="http://testserver/">' in landing and 'hreflang="en"' in landing
    assert 'application/ld+json' in landing and 'Navisense GmbH' in landing
    english = client.get('/features?lang=en').text
    assert 'lang="en"' in english and 'Score67 Features: Live Scoreboards, Chat' in english and '?lang=en">' in english
    # Games, the Flutter app and moderation stay out of search results.
    slug = create(client)['slug']
    assert '<meta name="robots" content="noindex">' in client.get(f'/s/{slug}').text
    assert client.get(f'/s/{slug}').headers['x-robots-tag'] == 'noindex'
    robots = client.get('/robots.txt').text
    assert 'Disallow: /api/' in robots and 'Sitemap: http://testserver/sitemap.xml' in robots
    sitemap = client.get('/sitemap.xml')
    assert sitemap.headers['content-type'].startswith('application/xml')
    assert '<loc>http://testserver/features?lang=en</loc>' in sitemap.text and 'hreflang="x-default"' in sitemap.text


def test_guide_pages_in_both_languages_and_in_the_sitemap(system):
    from score67.guides import GUIDES
    app, client = system
    sitemap = client.get('/sitemap.xml').text
    for path in GUIDES:
        de, en = client.get(path), client.get(f'{path}?lang=en')
        assert de.status_code == 200 and en.status_code == 200, path
        assert 'lang="de"' in de.text and 'lang="en"' in en.text
        assert '<h1>' in de.text and '· Score67</title>' in de.text and '<link rel="canonical"' in de.text
        assert f'<loc>http://testserver{path}</loc>' in sitemap
    assert '/basketball-liveticker' in client.get('/').text


def test_display_feed_labels_and_clock():
    from score67 import display_feed
    from score67.domain import initial_state
    s = initial_state(8, 5, 'basketball')
    assert display_feed.period_label(s) == ''
    s.update(period=5, phase='period_running')
    assert display_feed.period_label(s) == '5/8'
    s.update(period=9, period_count=8)
    assert display_feed.period_label(s) == 'OT1'
    q = initial_state(4, 10, 'basketball')
    q.update(period=3, phase='period_running')
    q['clock'].update(running=True, started_at=1_000_000, elapsed_ms=0)
    c = display_feed.clock(q, 1_000_000 + 125_000)
    assert display_feed.period_label(q) == 'Q3' and c['direction'] == 'down' and c['ms'] == 600_000 - 125_000 and c['running']
    f = initial_state(2, 45, 'football')
    f.update(period=2, phase='period_running')
    f['clock'].update(running=False, started_at=None, elapsed_ms=60_000)
    assert display_feed.period_label(f) == 'H2'
    assert display_feed.clock(f, 0) == {'visible': True, 'running': False, 'direction': 'up', 'ms': 45 * 60_000 + 60_000, 'at': 0}
    assert display_feed.clock(initial_state(), 0) == {'visible': False}


def test_self_registering_led_display_flow(system):
    app, client = system
    key = 'k' * 40
    device = TestClient(app)
    first = device.post('/api/display/register', json={'device_key': key, 'fw': '0.1.0'}).json()
    assert len(first['code']) == 6 and first['token']
    again = device.post('/api/display/register', json={'device_key': key}).json()
    assert again['display_id'] == first['display_id'] and again['token'] != first['token'] and again['code'] == first['code']
    token = again['token']
    # The old token is gone; the panel shows its code.
    assert device.get('/api/display/state?format=compact', headers={'Authorization': f'Bearer {first["token"]}'}).status_code == 401
    feed = lambda: device.get('/api/display/state?format=compact', headers={'Authorization': f'Bearer {token}'}).json()
    assert feed()['mode'] == 'pairing' and feed()['code'] == first['code'] and feed()['v'] == 1
    # Claim in the app with the code from the panel (any spelling).
    assert client.post('/api/displays/claim', json={'code': 'ZZZZZZ'}).status_code == 404
    info = client.post('/api/displays/claim', json={'code': first['code'].lower(), 'name': 'Halle 1'}).json()
    assert info['device'] and info['name'] == 'Halle 1' and info['fw_version'] == '0.1.0'
    assert client.post('/api/displays/claim', json={'code': first['code']}).status_code == 404   # used codes expire
    assert feed()['mode'] == 'idle'
    # The panel keeps showing a (new) code; a second person who reads it becomes an owner too.
    coach = TestClient(app)
    assert coach.post('/api/displays/claim', json={'code': feed()['code']}).json()['id'] == info['id']
    assert coach.get('/api/displays').json()['displays'][0]['id'] == info['id']
    assert len(client.get('/api/displays').json()['displays']) == 1
    # Assign a basketball board; the compact feed carries the game, not the whole state.
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': 8, 'period_length_min': 5}).json()['slug']
    command(client, slug, 'settings', {'home': {'name': 'Bramfeld', 'short': 'BRA'}})
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 3})
    command(client, slug, 'team_foul', {'team': 'away'}) if state(client, slug)['foul_mode'] != 'personal' else None
    client.put(f'/api/displays/{info["id"]}', json={'board': slug, 'brightness': 40})
    game = feed()
    assert game['mode'] == 'game' and game['home']['short'] == 'BRA' and game['home']['score'] == 3
    assert game['period'] == '1/8' and game['clock']['direction'] == 'down' and game['clock']['ms'] == 300_000
    assert game['brightness'] == 40 and game['lang'] == 'de' and 'events' not in str(game) and len(str(game)) < 800
    # Identify, live socket and status from the device.
    assert client.post(f'/api/displays/{info["id"]}/identify', json={}).status_code == 200
    with device.websocket_connect(f'/ws/display?token={token}&format=compact') as ws:
        live = ws.receive_json()
        assert live['mode'] == 'game' and live['identify'] is True
        ws.send_text('{"fw": "0.2.0", "rssi": -61, "uptime": 42}')
        ws.send_text('not json')
        command(client, slug, 'score', {'team': 'away', 'points': 2})
        update = ws.receive_json()
        assert update['guest']['score'] == 2 and update['seq'] >= live['seq']
    listed = client.get('/api/displays').json()['displays'][0]
    assert (listed['fw_version'], listed['rssi'], listed['online']) == ('0.2.0', -61, True)
    # A known key after the claim: new token, still claimed, no code.
    third = device.post('/api/display/register', json={'device_key': key}).json()
    assert third['display_id'] == info['id'] and third['code'] is None
    # Removing it in the app ends the device's access.
    client.delete(f'/api/displays/{info["id"]}')
    assert device.get('/api/display/state?format=compact', headers={'Authorization': f'Bearer {third["token"]}'}).status_code == 401


def test_led_panel_connected_from_sharing_tab(system):
    app, client = system
    device = TestClient(app)
    reg = device.post('/api/display/register', json={'device_key': 'g' * 40, 'fw': '0.1.0'}).json()
    auth = {'Authorization': f'Bearer {reg["token"]}'}
    feed = lambda: device.get('/api/display/state?format=compact', headers=auth).json()
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    command(client, slug, 'settings', {'home': {'name': 'Bramfeld', 'short': 'BRA'}})
    # Only the game's controllers; a stranger with the code gets nowhere.
    stranger = TestClient(app)
    assert stranger.post(f'/api/s/{slug}/displays', json={'code': reg['code']}).status_code == 401
    assert client.post(f'/api/s/{slug}/displays', json={'code': 'ZZZZZZ'}).status_code == 404
    # The unclaimed panel's code connects it straight to this game; the code changes after use.
    info = client.post(f'/api/s/{slug}/displays', json={'code': reg['code'].lower()}).json()
    assert info['board'] == slug and info['code'] is None
    game = feed()
    assert game['mode'] == 'game' and game['home']['short'] == 'BRA' and game['code'] != reg['code']
    assert client.post(f'/api/s/{slug}/displays', json={'code': reg['code']}).status_code == 404
    listed = client.get(f'/api/s/{slug}/displays').json()['displays']
    assert [(d['id'], d['board'], d['managed']) for d in listed] == [(info['id'], slug, True)]
    assert client.get('/api/displays').json()['displays'][0]['id'] == info['id']
    # A second coach in the hall reads the current code off the panel and takes it for their game.
    coach = TestClient(app)
    other = coach.post('/api/scoreboards', json={'sport': 'football'}).json()['slug']
    assert coach.post(f'/api/s/{other}/displays', json={'code': game['code']}).json()['board'] == other
    assert feed()['mode'] == 'game' and feed()['sport'] == 'football'
    assert client.get(f'/api/s/{slug}/displays').json()['displays'][0]['board'] == other
    # The first browser still manages it and switches it back without a code.
    assert client.put(f'/api/s/{slug}/displays/{info["id"]}', json={}).json()['board'] == slug
    assert stranger.put(f'/api/s/{slug}/displays/{info["id"]}', json={}).status_code == 401
    # Opening another of my games in the control center takes my following panels along;
    # a panel pinned to its game (follow off) stays.
    third = client.post('/api/scoreboards', json={'sport': 'football'}).json()['slug']
    moved = client.post(f'/api/s/{third}/displays/follow', json={}).json()['displays']
    assert [(d['id'], d['board'], d['follow']) for d in moved] == [(info['id'], third, True)]
    assert client.put(f'/api/displays/{info["id"]}', json={'follow': False}).json()['follow'] is False
    assert client.post(f'/api/s/{slug}/displays/follow', json={}).json()['displays'][0]['board'] == third
    client.put(f'/api/s/{slug}/displays/{info["id"]}', json={})   # explicit "show here" still works
    assert stranger.post(f'/api/s/{slug}/displays/follow', json={}).status_code == 401
    # A finished game does not pull a following panel away from its current one.
    client.put(f'/api/displays/{info["id"]}', json={'follow': True})
    command(client, third, 'period_start')
    command(client, third, 'game_end')
    assert client.post(f'/api/s/{third}/displays/follow', json={}).json()['displays'][0]['board'] == slug
    # Disconnect: the panel goes idle and shows its code for the next game.
    assert coach.delete(f'/api/s/{other}/displays/{info["id"]}').status_code == 404   # not showing their game
    assert client.delete(f'/api/s/{slug}/displays/{info["id"]}').json() == {'ok': True}
    idle = feed()
    assert idle['mode'] == 'idle' and len(idle['code']) == 6


def test_led_messages_interrupt_the_score(system, monkeypatch):
    import time
    from score67 import led_messages
    app, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': 4, 'period_length_min': 10}).json()['slug']
    command(client, slug, 'settings', {'home': {'name': 'Bramfeld', 'short': 'BRA', 'color': '#1d4ed8'}})
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 3})
    command(client, slug, 'score', {'team': 'away', 'points': 2})
    command(client, slug, 'period_end')
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'away', 'points': 2})
    command(client, slug, 'score', {'team': 'away', 'points': 3})
    url = f'/api/s/{slug}/led/message'
    # Only controllers; texts the font cannot draw are cleaned, umlauts spelled out.
    assert TestClient(app).post(url, json={'text': 'Hallo'}).status_code == 401
    assert client.post(url, json={'text': '  '}).status_code == 422
    assert client.post(url, json={'text': 'x', 'icon': 'unicorn'}).status_code == 422
    msg = client.post(url, json={'text': 'Grüße an alle 💪 Fans!', 'icon': 'heart', 'effect': 'blink', 'seconds': 5}).json()
    assert msg['text'] == 'GRUESSE AN ALLE FANS!' and msg['icon'] == 'heart' and 0 < msg['ms'] <= 5000
    feed = client.get(f'/api/s/{slug}/led').json()
    assert feed['mode'] == 'game' and feed['msg']['id'] == msg['id'] and feed['home']['short'] == 'BRA'
    # Graphics are computed from the game: points per period and the lead over time.
    periods = client.post(url, json={'kind': 'periods'}).json()
    assert periods['periods'] == [[3, 2], [0, 5]] and periods['home'] == {'short': 'BRA', 'color': '#1d4ed8'}
    lead = client.post(url, json={'kind': 'lead'}).json()['lead']
    assert len(lead) == led_messages.LEAD_COLUMNS and lead[0] == 0 and lead[-1] == -4 and max(lead) == 3
    # Panels showing the game get it too; it ends by itself or when cleared.
    device = TestClient(app)
    reg = device.post('/api/display/register', json={'device_key': 'm' * 40}).json()
    client.post(f'/api/s/{slug}/displays', json={'code': reg['code']})
    panel = lambda: device.get('/api/display/state?format=compact', headers={'Authorization': f'Bearer {reg["token"]}'}).json()
    assert panel()['msg']['kind'] == 'lead'
    for logo in ('polonia', 'bram'):
        assert client.post(url, json={'kind': logo, 'seconds': 5}).status_code == 200
        assert panel()['msg']['kind'] == logo
    later = time.time() + 61
    monkeypatch.setattr(led_messages.time, 'time', lambda: later)
    assert 'msg' not in panel()
    monkeypatch.undo()
    client.post(url, json={'text': 'Defense'})
    assert client.delete(url).json() == {'ok': True} and 'msg' not in panel()


def test_idle_panels_go_back_to_their_code(system):
    import time
    from score67.app import release_idle_displays
    app, client = system
    device = TestClient(app)
    reg = device.post('/api/display/register', json={'device_key': 'i' * 40}).json()
    slug = client.post('/api/scoreboards', json={'sport': 'basketball', 'period_count': 1, 'period_length_min': 1}).json()['slug']
    client.post(f'/api/s/{slug}/displays', json={'code': reg['code']})
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 2})
    feed = lambda: device.get('/api/display/state?format=compact', headers={'Authorization': f'Bearer {reg["token"]}'}).json()
    assert feed()['mode'] == 'game'
    now = time.time()
    with app.state.sessions() as db:
        # Running game, recent activity: stays. Quiet for 7 h: released.
        assert release_idle_displays(db, now + 3600) == 0
        assert release_idle_displays(db, now + 7 * 3600) == 1
        db.commit()
    assert feed()['mode'] == 'idle' and len(feed()['code']) == 6
    # Shown again, then the game ends: released two hours after the final whistle.
    client.put(f'/api/s/{slug}/displays/{reg["display_id"]}', json={})
    command(client, slug, 'game_end')
    with app.state.sessions() as db:
        assert release_idle_displays(db, time.time() + 3600) == 0
        assert release_idle_displays(db, time.time() + 2.5 * 3600) == 1
        db.commit()
    assert feed()['mode'] == 'idle'


def test_app_pages_are_served(system):
    app, client = system
    for path in ('/dashboard', '/settings', '/login'):
        r = client.get(path)
        assert r.status_code in (200, 503) and r.headers.get('x-robots-tag', 'noindex') == 'noindex', path


def test_led_preview_page_and_feed(system):
    app, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    command(client, slug, 'settings', {'home': {'name': 'Bramfeld', 'short': 'BRA'}})
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 2})
    feed = TestClient(app).get(f'/api/s/{slug}/led').json()
    assert feed['mode'] == 'game' and feed['home']['short'] == 'BRA' and feed['home']['score'] == 2 and feed['period'] == 'Q1'
    page = client.get(f'/s/{slug}/led').text
    assert f'data-led-slug="{slug}"' in page and '/static/led.mjs' in page and 'noindex' in page
    assert f'href="/s/{slug}/led"' in client.get(f'/s/{slug}').text
    assert 'data-led-demo' in client.get('/anzeigetafel/led-bauanleitung').text


def test_firmware_releases_offer_and_download(system, monkeypatch):
    import base64, hashlib
    app, client = system
    monkeypatch.setenv('FIRMWARE_ADMIN_TOKEN', 'operator-secret')
    admin = {'Authorization': 'Bearer operator-secret'}
    image = bytes(range(256)) * 400   # 100 KB, larger than the normal 16 KB request limit
    body = {'version': '0.2.0', 'channel': 'test', 'notes': 'Zehntel', 'sha256': hashlib.sha256(image).hexdigest(),
            'data': base64.b64encode(image).decode()}
    assert client.post('/api/firmware', json=body).status_code == 401
    assert client.post('/api/firmware', json=body, headers={'Authorization': 'Bearer wrong'}).status_code == 401
    assert client.post('/api/firmware', json={**body, 'sha256': '0' * 64}, headers=admin).json()['error'] == 'sha256_mismatch'
    assert client.post('/api/firmware', json={**body, 'version': 'v2'}, headers=admin).status_code == 422
    created = client.post('/api/firmware', json=body, headers=admin)
    assert created.status_code == 201 and created.json()['size'] == len(image)
    assert client.post('/api/firmware', json=body, headers=admin).status_code == 409
    assert [r['version'] for r in client.get('/api/firmware', headers=admin).json()['releases']] == ['0.2.0']
    # A claimed panel on 0.1.0: test releases only with beta switched on.
    device = TestClient(app)
    reg = device.post('/api/display/register', json={'device_key': 'o' * 40, 'fw': '0.1.0'}).json()
    info = client.post('/api/displays/claim', json={'code': reg['code']}).json()
    auth = {'Authorization': f'Bearer {reg["token"]}'}
    feed = lambda: device.get('/api/display/state?format=compact', headers=auth).json()
    assert 'firmware' not in feed()
    assert client.put(f'/api/displays/{info["id"]}', json={'beta': True}).json()['update'] == '0.2.0'
    offered = feed()['firmware']
    assert offered == {'version': '0.2.0', 'url': '/fw/0.2.0.bin', 'sha256': body['sha256'], 'size': len(image)}
    client.put(f'/api/displays/{info["id"]}', json={'beta': False})
    assert 'firmware' not in feed()
    client.put('/api/firmware/0.2.0', json={'channel': 'stable'}, headers=admin)
    assert feed()['firmware']['version'] == '0.2.0'
    # Download only for panels (or the operator); the bytes match the checksum.
    assert device.get('/fw/0.2.0.bin').status_code == 401
    got = device.get('/fw/0.2.0.bin', headers=auth)
    assert got.status_code == 200 and hashlib.sha256(got.content).hexdigest() == body['sha256']
    assert got.headers['x-checksum-sha256'] == body['sha256']
    # The panel reports progress and its new version; then nothing is offered any more.
    with device.websocket_connect(f'/ws/display?token={reg["token"]}&format=compact') as ws:
        ws.receive_json()
        ws.send_text('{"ota": "installed 0.2.0", "fw": "0.2.0"}')
        ws.send_text('{"rssi": -50}')
        ws.receive_json()   # the offer disappears with the new version
    listed = client.get('/api/displays').json()['displays'][0]
    assert (listed['fw_version'], listed['ota_status'], listed['update']) == ('0.2.0', 'installed 0.2.0', None)
    # Withdrawn releases are neither offered nor downloadable.
    client.put('/api/firmware/0.2.0', json={'channel': 'off'}, headers=admin)
    assert device.get('/fw/0.2.0.bin', headers=auth).status_code == 404


DATA = Path(__file__).parent / 'samples'


@pytest.fixture
def offline_sites(monkeypatch):
    """League websites served from saved copies; no network in tests."""
    from score67 import fixtures
    fixtures._fonts.clear()
    files = {'https://www.fussball.de/spiel/-/spiel/031KHH4BP4000000VS5489BTVSRD0UH9': 'fussball_youth.html',
             'https://www.fussball.de/export.fontface/-/format/ttf/id/azfc2urv/type/font': 'fussball_font_azfc2urv.ttf',
             'https://www.basketball-bund.net/rest/match/id/2978034/matchInfo': 'basketball_2978034.json'}

    def fetch(url, accept='text/html'):
        if url.startswith('https://nominatim.openstreetmap.org/'):
            return b'[{"lat": "53.5893", "lon": "10.0612"}]'
        if url.startswith('https://www.fussball.de/export.media/-/action/getLogo/format/9/id/'):
            if url.endswith(URANIA):
                return logo_png(200)
            raise fixtures.FixtureError('fixture_not_found')  # club without a logo
        if url not in files:
            raise fixtures.FixtureError('fixture_not_found')
        return (DATA / files[url]).read_bytes()
    monkeypatch.setattr(fixtures, 'fetch', fetch)
    monkeypatch.setattr(fixtures, '_geo_last', [0.0])
    fixtures._logos.clear()
    return fixtures


def logo_png(size):
    import io
    from PIL import Image
    out = io.BytesIO()
    Image.new('RGBA', (size, size), (0, 128, 0, 255)).save(out, 'PNG')
    return out.getvalue()


YOUTH = 'https://www.fussball.de/spiel/-/spiel/031KHH4BP4000000VS5489BTVSRD0UH9'
URANIA, POLONIA = '00ES8GN8JC00001MVV0AG08LVUPGND5I', '00ES8GN8JC00002EVV0AG08LVUPGND5I'


def test_fixture_lookup_fussball_de_youth_game(system, offline_sites):
    _, client = system
    r = client.post('/api/fixtures/lookup', json={
        'url': 'https://www.fussball.de/spiel/urania-3c-jun-j1-7er-polonia-2c-jun-j1-7er/-/spiel/031KHH4BP4000000VS5489BTVSRD0UH9#!/'})
    assert r.status_code == 200, r.text
    f = r.json()
    assert f['sport'] == 'football' and f['source'] == 'fussball.de'
    assert f['home'] == {'name': 'Urania 3.C-Jun. (J1) 7er', 'club': 'Urania', 'team': '3.C-Jun. (J1) 7er', 'short': 'URA',
                         'club_id': URANIA}
    assert f['away']['club'] == 'Polonia' and f['away']['short'] == 'POL'
    # Date and time come from the scrambled web font.
    assert (f['date'], f['time']) == ('07.11.2026', '13:00')
    assert f['kickoff'] == 1794052800000  # 13:00 CET
    assert f['league'] == 'C-Junioren Kreisklasse' and f['matchday'] == '6. Spieltag'
    assert f['game_number'] == '035575016' and f['season'] == '2026/2027'
    assert f['venue']['street'] == 'Habichtstr. 14' and f['venue']['zip'] == '22305'
    assert f['format'] == {'period_count': 2, 'period_length_min': 35, 'lineup_size': 7}
    assert f['location']['visible'] is False and f['location']['lat'] == 53.5893
    assert f['description'] == 'C-Junioren Kreisklasse · 6. Spieltag'


def test_fixture_lookup_basketball_bund(system, offline_sites):
    _, client = system
    f = client.post('/api/fixtures/lookup', json={'url': 'https://www.basketball-bund.net/static/#/spiel/2978034'}).json()
    assert f['sport'] == 'basketball' and f['game_number'] == '1542'
    assert f['home']['short'] == 'BCH' and f['away']['short'] == 'BSV'
    assert f['home']['club'] == 'BC Hamburg e.V.' and f['home']['team'] == '(1)'
    assert (f['date'], f['time']) == ('11.10.2026', '11:30')
    assert f['format'] == {'period_count': 8, 'period_length_min': 5}  # U11 = mini basketball
    assert f['venue']['address'] == 'Handelsschule und Wirtschaftsgymnasium City Nord, Tessenowweg 3, 22297 Hamburg'


def test_fixture_lookup_rejects_other_links(system, offline_sites):
    _, client = system
    for url in ('https://example.com/spiel/2978034', 'https://www.fussball.de/verein/croatia-hamburg/-/id/00ES8GN8JC000037VV0AG08LVUPGND5I'):
        r = client.post('/api/fixtures/lookup', json={'url': url})
        assert r.status_code == 422 and r.json()['error'] == 'fixture_url'
    r = client.post('/api/fixtures/lookup', json={'url': 'https://www.basketball-bund.net/static/#/spiel/1'})
    assert r.status_code == 422  # too short to be a game id
    r = client.post('/api/fixtures/lookup', json={'url': 'https://www.basketball-bund.net/static/#/spiel/12345'})
    assert r.status_code == 404 and r.json()['error'] == 'fixture_not_found'


def test_create_board_and_game_with_fixture(system, offline_sites):
    _, client = system
    f = client.post('/api/fixtures/lookup', json={'url': 'https://www.basketball-bund.net/static/#/spiel/2978034'}).json()
    f['url'] = 'javascript:alert(1)'
    f['home']['name'] = '<b>x</b>' * 30
    r = client.post('/api/scoreboards', json={'sport': 'basketball', 'home': f['home']['name'][:60], 'away': 'Bramfelder SV (1)',
                                              'home_short': 'bch', 'fixture': f, 'location': f['location']})
    assert r.status_code == 201, r.text
    slug = r.json()['slug']
    s = client.get(f'/api/s/{slug}/control-state').json()
    assert s['home']['short'] == 'BCH' and s['away']['short'] == 'BRA'  # guessed when not given
    assert s['away']['name'] == 'Bramfelder SV (1)'
    assert s['fixture']['game_number'] == '1542' and s['fixture']['url'] == ''  # only links to the source site
    assert len(s['fixture']['home']['name']) <= 80
    assert 'fixture' not in state(client, slug)  # controllers and dashboard only
    r = client.post(f'/api/s/{slug}/matches', json={'command_id': str(uuid4()), 'sport': 'basketball', 'home': 'A', 'away': 'B',
                                                   'fixture': {'source': 'elsewhere'}})
    assert r.status_code == 201
    games = client.get('/api/dashboard').json()['boards'][0]['matches']
    assert sorted(bool(g['fixture']) for g in games) == [False, True]


def test_fixture_logos_from_fussball_de(system, offline_sites):
    _, client = system
    f = client.post('/api/fixtures/lookup', json={'url': YOUTH}).json()
    assert f['home']['club_id'] == URANIA and f['away']['club_id'] == POLONIA
    preview = client.get(f'/api/fixtures/logo/{URANIA}.png')
    assert preview.status_code == 200 and preview.headers['content-type'] == 'image/png'
    assert client.get(f'/api/fixtures/logo/{POLONIA}.png').status_code == 404
    assert client.get('/api/fixtures/logo/..%2Fx.png').status_code == 404
    # Without the switch no logos; with it the club that has one gets it.
    plain = client.post('/api/scoreboards', json={'home': 'Urania', 'away': 'Polonia', 'fixture': f}).json()
    assert 'logo' not in client.get(f"/api/s/{plain['slug']}/control-state").json()['home']
    r = client.post('/api/scoreboards', json={'home': 'Urania', 'away': 'Polonia', 'fixture': f, 'fixture_logos': True})
    s = client.get(f"/api/s/{r.json()['slug']}/control-state").json()
    assert s['home']['logo'].startswith('/media/') and not s['away'].get('logo')
    assert s['fixture']['home']['club_id'] == URANIA
    image = client.get(s['home']['logo'])
    assert image.status_code == 200 and image.content.startswith(b'\x89PNG')
    # Preparing the next game on the same board works the same way.
    r = client.post(f"/api/s/{s['scoreboard']}/matches", json={'command_id': str(uuid4()), 'home': 'Urania', 'away': 'Polonia',
                                                              'fixture': f, 'fixture_logos': True})
    assert r.status_code == 201, r.text
    game = client.get(f"/api/s/{s['scoreboard']}/matches/{r.json()['match_id']}/control-state").json()
    assert game['home']['logo'].startswith('/media/')


def test_abandoned_game_with_scoring_is_ended_not_trashed(system):
    app, client = system
    tennis = client.post('/api/scoreboards', json={'sport': 'tennis'}).json()['slug']
    command(client, tennis, 'period_start')
    for _ in range(3):
        command(client, tennis, 'tennis_point', {'team': 'home'})
    with app.state.sessions() as db:
        assert clean_matches(db, __import__('time').time() + 25 * 3600) == (0, 0)
    s = state(client, tennis)
    assert s['phase'] == 'finished' and s['events'][-1].get('automatic')
    game = next(g for b in client.get('/api/dashboard').json()['boards'] if b['slug'] == tennis for g in b['matches'])
    assert not game['trashed']


def test_one_device_cookie_for_any_number_of_boards(system):
    _, client = system
    slugs = {create(client)['slug'] for _ in range(30)}
    assert set(client.cookies.keys()) == {'score67_device'}
    assert {b['slug'] for b in client.get('/api/dashboard').json()['boards']} == slugs
    assert all(state(client, slug) and command(client, slug, 'period_start').status_code == 200 for slug in list(slugs)[:3])


def test_old_per_board_cookies_are_taken_over(system):
    app, client = system
    a = create(client)['slug']
    import hashlib
    token = 'legacy-token-' + a
    with app.state.sessions() as db:
        db.add(Admin(id=str(uuid4()), slug=a, token_hash=hashlib.sha256(token.encode()).hexdigest(), label='Browser',
                     last_seen_at=__import__('time').time()))
        db.commit()
    old = TestClient(app)
    old.cookies.set(f'score67_{a}', token, domain='testserver.local')
    assert [b['slug'] for b in old.get('/api/dashboard').json()['boards']] == [a]
    assert f'score67_{a}' not in old.cookies and 'score67_device' in old.cookies
    assert [b['slug'] for b in old.get('/api/dashboard').json()['boards']] == [a]
    assert command(old, a, 'period_start').status_code == 200


def test_connect_link_shares_the_board_list_between_browsers(system):
    app, phone = system
    first, second = create(phone)['slug'], create(phone)['slug']
    laptop = TestClient(app)
    own = create(laptop)['slug']
    assert laptop.post('/api/device/join', json={'code': 'x' * 24}).status_code == 404
    code = phone.post('/api/device/link', json={}).json()['code']
    assert laptop.post('/api/device/join', json={'code': code}).json() == {'boards': 3}
    for browser in (phone, laptop):
        listing = browser.get('/api/dashboard').json()
        assert {b['slug'] for b in listing['boards']} == {first, second, own}
        assert listing['device'] == {'browsers': 2}
    # Later boards show up on both, and the viewer page offers "Controller" without PIN.
    later = create(laptop)['slug']
    assert later in {b['slug'] for b in phone.get('/api/dashboard').json()['boards']}
    assert 'id="controller-button"' in phone.get(f'/s/{later}').text
    # A browser after "clear browsing data" gets everything back with the saved link.
    fresh = TestClient(app)
    assert fresh.post('/api/device/join', json={'code': code}).json() == {'boards': 4}
    assert command(fresh, first, 'period_start').status_code == 200
    # A new link replaces the old one.
    phone.post('/api/device/link', json={})
    assert TestClient(app).post('/api/device/join', json={'code': code}).status_code == 404


def test_optional_creator_nickname_is_public(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'creator': '  Coach   Carsten '}).json()['slug']
    assert client.get(f'/api/s/{slug}/state').json()['creator'] == 'Coach Carsten'
    assert client.get('/api/dashboard').json()['boards'][0]['creator'] == 'Coach Carsten'
    assert client.post('/api/scoreboards', json={'creator': 'x' * 41}).status_code == 422
    plain = create(client)['slug']
    assert client.get(f'/api/s/{plain}/state').json()['creator'] is None
    # Editing the description alone keeps the nickname; sending it changes it.
    assert client.put(f'/api/s/{slug}/description', json={'description': 'Halle 2'}).json()['creator'] == 'Coach Carsten'
    assert client.put(f'/api/s/{slug}/description', json={'description': 'Halle 2', 'creator': ''}).json()['creator'] is None
    command(client, plain, 'period_start')
    client.put(f'/api/s/{plain}/description', json={'description': None, 'creator': 'Mia'})
    live = client.get('/api/live').json()
    assert next(g for g in live['games'] if g['scoreboard'] == plain)['creator'] == 'Mia'


def test_football_extra_time_and_penalty_shootout(system):
    _, client = system
    slug = create(client)['slug']
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 1})
    command(client, slug, 'period_end')
    command(client, slug, 'period_start')
    # Not level: regular time cannot just end, extra time and shootout are refused.
    assert command(client, slug, 'period_end').status_code == 422
    command(client, slug, 'score', {'team': 'away', 'points': 1})
    s = command(client, slug, 'period_end').json()
    assert s['phase'] == 'break' and s['period'] == 2
    assert command(client, slug, 'period_start').status_code == 422
    # Extra time: 2 × 15 after 2 × 45 by default, or a chosen length.
    assert command(client, slug, 'overtime_start', {'length_min': 31}).status_code == 422
    s = command(client, slug, 'overtime_start', {'length_min': 10}).json()
    assert (s['phase'], s['period'], s['overtime_length_min']) == ('period_running', 3, 10)
    assert s['events'][-1]['period_duration_ms'] == 600000
    command(client, slug, 'score', {'team': 'home', 'points': 1})
    assert command(client, slug, 'period_end').json()['phase'] == 'break'
    assert command(client, slug, 'shootout_start').status_code == 422   # between the halves
    s = command(client, slug, 'overtime_start').json()  # second half, whatever the score
    assert s['period'] == 4 and s['overtime_length_min'] == 10
    assert command(client, slug, 'period_end').status_code == 422      # 2:1, the game ends instead
    command(client, slug, 'score', {'team': 'away', 'points': 1})
    assert command(client, slug, 'period_end').json()['phase'] == 'break'
    assert command(client, slug, 'overtime_start').status_code == 422  # only two halves
    # Shootout: guest first, alternating; the score of the game stays 2:2.
    s = command(client, slug, 'shootout_start', {'first': 'away'}).json()
    assert s['phase'] == 'shootout' and s['shootout']['next'] == 'away'
    for scored in (True, True, False, True, True, True, True, False):   # away, home, away, ...
        s = command(client, slug, 'shootout_kick', {'scored': scored}).json()
    assert s['shootout']['score'] == [3, 3] and s['phase'] == 'shootout'
    assert s['home']['score'] == s['away']['score'] == 2
    s = command(client, slug, 'shootout_kick', {'scored': False}).json()   # away 5th misses
    assert s['shootout']['next'] == 'home' and s['phase'] == 'shootout'
    s = command(client, slug, 'shootout_kick', {'scored': True}).json()    # home 5th: 4:3, decided
    assert s['shootout']['winner'] == 'home' and s['shootout']['score'] == [4, 3]
    assert s['phase'] == 'finished' and s['events'][-1]['decided']
    # Undo first reopens the shootout, then takes back the kick.
    s = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
    assert s['phase'] == 'shootout' and s['shootout']['winner'] == 'home'
    assert command(client, slug, 'shootout_kick', {'scored': True}).status_code == 422
    kick = [e for e in s['events'] if not e['cancelled']][-1]
    assert kick['type'] == 'shootout_kick' and kick['team'] == 'home' and kick['scored']
    s = command(client, slug, 'undo', {'event_id': kick['id']}).json()
    assert s['shootout']['next'] == 'home' and s['shootout']['score'] == [3, 3]
    assert command(client, slug, 'shootout_kick', {'scored': 'yes'}).status_code == 422
    live = client.get('/api/live').json()
    assert live['games'][0]['shootout']['score'] == [3, 3]


def test_shootout_straight_after_regular_time_and_sudden_death(system):
    _, client = system
    slug = create(client)['slug']
    command(client, slug, 'settings', {'period_count': 1, 'period_length_min': 10})
    command(client, slug, 'period_start')
    assert command(client, slug, 'shootout_start').status_code == 422   # still running
    command(client, slug, 'period_end')
    s = command(client, slug, 'shootout_start').json()
    assert s['shootout']['first'] == 'home'
    for _ in range(10):   # 5 each, all scored: 5:5, sudden death follows
        s = command(client, slug, 'shootout_kick', {'scored': True}).json()
    assert s['shootout']['score'] == [5, 5] and s['shootout']['winner'] is None
    s = command(client, slug, 'shootout_kick', {'scored': True}).json()   # home 6th
    assert s['phase'] == 'shootout' and s['shootout']['next'] == 'away'
    s = command(client, slug, 'shootout_kick', {'scored': False}).json()  # away 6th misses
    assert s['shootout']['winner'] == 'home' and s['phase'] == 'finished'
    finished = client.get('/api/live').json()['finished'][0]
    assert finished['shootout']['score'] == [6, 5] and not finished['automatic']


def test_shootout_summary_decides_early():
    from score67.domain import shootout_summary
    def summary(first, *kicks):
        order = [first, 'away' if first == 'home' else 'home']
        return shootout_summary({'first': first, 'kicks': [
            {'team': order[i % 2], 'scored': k} for i, k in enumerate(kicks)]})
    assert summary('home', True, False, True, False, True, False)['winner'] == 'home'   # 3:0 after 3 rounds
    assert summary('home', True, False, True, False, True)['winner'] is None             # away can still reach 3
    assert summary('away', False, True, False, True, False, True)['winner'] == 'home'
    assert summary('home')['next'] == 'home' and summary('home', True)['next'] == 'away'


def test_led_feed_and_preview_for_extra_time_and_shootout():
    from score67.display_feed import clock, period_label
    from score67.preview import summary
    s = {'sport': 'football', 'phase': 'period_running', 'period': 4, 'period_count': 2, 'period_length_min': 45,
         'overtime_length_min': 15, 'clock': {'enabled': True, 'running': False, 'elapsed_ms': 60000, 'started_at': None}}
    assert period_label(s) == 'ET2'
    assert clock(s, 0)['ms'] == 106 * 60000
    s.update(phase='shootout', shootout={'score': [4, 3]})
    assert period_label(s) == 'P 4:3' and clock(s, 0) == {'visible': False}
    s.update(phase='finished', home={'name': 'A', 'score': 2}, away={'name': 'B', 'score': 2})
    assert summary(s, 'de')[0] == 'A 2 : 2 B (4:3 i. E.) · ENDSTAND'


def test_saved_teams_belong_to_the_browser(system):
    _, client = system
    body = {"sport": "basketball", "name": "BHV U14", "short": "BHV", "color": "#c8102e",
            "players": [{"number": "07", "name": "Kim"}, {"number": "4", "name": ""}]}
    saved = client.post("/api/teams", json=body)
    assert saved.status_code == 200
    assert saved.json()["players"][0] == {"number": "7", "name": "Kim"}
    # The same name replaces the earlier version.
    client.post("/api/teams", json={**body, "name": "bhv u14", "players": [{"number": "9", "name": ""}]})
    teams = client.get("/api/teams?sport=basketball").json()["teams"]
    assert [len(t["players"]) for t in teams] == [1]
    assert client.get("/api/teams?sport=football").json()["teams"] == []
    # A repeated number is refused, also through the API.
    twice = {**body, "players": [{"number": "7", "name": ""}, {"number": "07", "name": ""}]}
    assert client.post("/api/teams", json=twice).status_code == 400
    # Another browser neither sees nor deletes it.
    cookies = dict(client.cookies)
    client.cookies.clear()
    assert client.get("/api/teams").json()["teams"] == []
    assert client.delete(f"/api/teams/{teams[0]['id']}").status_code == 404
    client.cookies.update(cookies)
    assert client.delete(f"/api/teams/{teams[0]['id']}").status_code == 200
    assert client.get("/api/teams").json()["teams"] == []


def test_period_jump_back_and_forward_keeps_entries(system):
    _, client = system
    slug = create(client)['slug']
    command(client, slug, 'settings', {'period_count': 4, 'period_length_min': 10})
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 1})
    command(client, slug, 'period_end')
    command(client, slug, 'period_start')  # period 2 started by mistake
    command(client, slug, 'score', {'team': 'away', 'points': 1})
    back = command(client, slug, 'period_set', {'period': 1}).json()
    # Football has no Play button: its clock runs on after the jump.
    assert back['period'] == 1 and back['phase'] == 'period_running' and back['clock']['running']
    assert back['home']['score'] == 1 and back['away']['score'] == 1
    # The jump itself can be undone.
    undone = command(client, slug, 'undo', {'event_id': back['events'][-1]['id']}).json()
    assert undone['period'] == 2
    forward = command(client, slug, 'period_set', {'period': 4}).json()
    assert forward['period'] == 4 and forward['clock']['elapsed_ms'] == 0
    # An ended game can be reopened; nonsense is refused.
    ended = command(client, slug, 'game_end').json()
    assert ended['phase'] == 'finished'
    reopened = command(client, slug, 'period_set', {'period': 4}).json()
    assert reopened['phase'] == 'period_running'
    assert command(client, slug, 'period_set', {'period': 4}).status_code == 422
    assert command(client, slug, 'period_set', {'period': 9}).status_code == 422


def test_controller_shortcuts_follow_unfinished_games_and_permissions(system):
    app, client = system
    slug = create(client)['slug']
    assert client.get('/api/active-games').json()['games'] == [
        {'slug': slug, 'home': 'Home', 'away': 'Guest'}]
    # Unstarted games remain reachable even after the former 24-hour limit.
    with app.state.sessions() as db:
        from score67.db import Match
        match = db.get(Match, state(client, slug)['match_id'])
        match.created_at -= 3 * 86400
        db.commit()
    assert client.get('/api/active-games').json()['games'][0]['slug'] == slug
    with TestClient(app) as stranger:
        assert stranger.get('/api/active-games').json() == {'games': []}
    for path in ['/', '/features', '/about', '/forum', '/live', '/impressum',
                 '/datenschutz', f'/s/{slug}', f'/s/{slug}/led']:
        assert '/static/active-games.mjs' in client.get(path).text
    assert '/static/active-games.mjs' not in client.get(f'/s/{slug}/overlay').text
    command(client, slug, 'game_end')
    assert client.get('/api/active-games').json() == {'games': []}
    command(client, slug, 'undo', {'event_id': state(client, slug)['events'][-1]['id']})
    assert client.get('/api/active-games').json()['games'][0]['slug'] == slug


def test_watching_now_counts_spectators_but_not_controller_or_reads(system):
    app, controller = system
    slug = create(controller)['slug']
    endpoint = f'/api/s/{slug}/audience'
    first, second = TestClient(app), TestClient(app)
    assert first.get(endpoint).json() == {'watching_now': 0}
    assert controller.post(endpoint, json={}).json() == {'watching_now': 0}
    assert first.post(endpoint, json={}).json() == {'watching_now': 1}
    assert first.cookies.get('score67_viewer')
    assert first.post(endpoint, json={}).json() == {'watching_now': 1}
    assert second.post(endpoint, json={}).json() == {'watching_now': 2}
    assert controller.get(endpoint).json() == {'watching_now': 2}
    assert controller.get(endpoint).headers['cache-control'] == 'no-store'
    assert 'id="watching-now"' in first.get(f'/s/{slug}').text
    assert 'id="watching-now"' not in first.get(f'/s/{slug}/overlay').text
    assert first.post('/api/s/nonexistent/audience', json={}).status_code == 404
    with app.state.sessions() as db:
        db.get(Board, slug).private = True
        db.commit()
    assert first.post(endpoint, json={}).status_code == 403
    assert first.get(endpoint).status_code == 403
    assert controller.get(endpoint).status_code == 200


def test_chat_shared_delivery_validation_moderation_and_privacy(system):
    app, controller = system
    slug = create(controller)['slug']
    endpoint = f'/api/s/{slug}/chat'
    spectator = TestClient(app)
    assert spectator.get(endpoint).json()['messages'] == []
    sent = spectator.post(endpoint, json={'text': '<script>alert(1)</script>'})
    assert sent.status_code == 201, sent.text
    message = sent.json()['messages'][0]
    assert message['name'] == '' and message['controller'] is False
    assert 0 <= sent.json()['server_now'] - message['created_at'] < 1000
    assert message['text'] == '<script>alert(1)</script>'
    assert controller.get(endpoint).json()['messages'] == sent.json()['messages']
    answer = controller.post(endpoint, json={'name': 'Scorer', 'text': 'Welcome!'}).json()['messages'][-1]
    assert answer['controller'] is True
    assert spectator.get(endpoint).json()['messages'][-1] == answer
    assert spectator.delete(f"{endpoint}/{message['id']}").status_code == 401
    assert controller.delete(f"{endpoint}/{message['id']}").json()['messages'] == [answer]
    assert answer['name'] == ''  # Older clients may still send a name; it is ignored.
    for body in [{'text': ' '}, {'text': 'a' * 501}, {}]:
        assert spectator.post(endpoint, json=body).status_code == 422
    assert spectator.post(endpoint, json={'name': 'Fan', 'text': 'Hi'},
                          headers={'Origin': 'https://unrelated.example'}).status_code == 403
    other = create(controller)['slug']
    assert spectator.get(f'/api/s/{other}/chat').json()['messages'] == []
    assert controller.delete(f"/api/s/{other}/chat/{answer['id']}").status_code == 404
    assert 'id="game-chat"' in spectator.get(f'/s/{slug}').text
    assert 'id="chat-name"' not in spectator.get(f'/s/{slug}').text
    assert 'id="game-chat"' not in spectator.get(f'/s/{slug}/overlay').text
    with app.state.sessions() as db:
        db.get(Board, slug).private = True
        db.commit()
    assert spectator.get(endpoint).status_code == 403
    assert spectator.post(endpoint, json={'name': 'Fan', 'text': 'hi'}).status_code == 403
    assert controller.get(endpoint).status_code == 200


def test_chat_rate_limit_and_recent_history(system):
    app, controller = system
    slug = create(controller)['slug']
    endpoint = f'/api/s/{slug}/chat'
    spectator = TestClient(app)
    for i in range(10):
        assert spectator.post(endpoint, json={'name': 'Fan', 'text': str(i)}).status_code == 201
    assert spectator.post(endpoint, json={'name': 'Fan', 'text': 'too many'}).status_code == 429
    from score67.db import ChatMessage
    with app.state.sessions() as db:
        for i in range(105):
            db.add(ChatMessage(id=str(uuid4()), slug=slug, name='Old', text=str(i),
                               controller=False, created_at=i))
        db.commit()
    result = controller.post(endpoint, json={'name': 'Scorer', 'text': 'Latest'})
    assert result.status_code == 201
    assert len(result.json()['messages']) == 100
    with app.state.sessions() as db:
        assert len(list(db.scalars(select(ChatMessage).where(ChatMessage.slug == slug)))) == 100


@pytest.mark.parametrize('system', [True], indirect=True)
def test_one_unfinished_scoreboard_per_device_until_end_or_trash(system):
    app, client = system
    slug = create(client)['slug']
    blocked = client.post('/api/scoreboards', json={})
    assert blocked.status_code == 409
    assert blocked.json()['error'] == 'active_scoreboard_exists'
    assert command(client, slug, 'archive').status_code == 409
    other = TestClient(app)
    other_board = create(other)
    assert client.post(f"/api/s/{other_board['slug']}/admin/claim", json={'pin': other_board['pin']}).status_code == 409
    assert command(client, slug, 'game_end').status_code == 200
    next_slug = create(client)['slug']
    assert client.get('/api/active-games').json()['games'][0]['slug'] == next_slug
    assert command(client, slug, 'new_match').status_code == 409
    assert command(client, slug, 'undo', {'event_id': state(client, slug)['events'][-1]['id']}).status_code == 409
    assert command(client, next_slug, 'trash').status_code == 200
    third = create(client)['slug']
    assert third != next_slug
    assert len(client.get('/api/dashboard').json()['boards']) == 3


@pytest.mark.parametrize('system', [True], indirect=True)
def test_creation_race_has_only_one_winner_on_known_device(system):
    app, client = system
    slug = create(client)['slug']
    command(client, slug, 'game_end')
    def attempt(_):
        tab = TestClient(app)
        tab.cookies.update(client.cookies)
        return tab.post('/api/scoreboards', json={}).status_code
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(attempt, range(2))) == [201, 409]


def test_release_update_page_and_cache_headers(system):
    _, client = system
    release = client.get('/api/release')
    import tomllib
    version = tomllib.loads((Path(__file__).parents[1] / 'pyproject.toml').read_text())['project']['version']
    assert release.status_code == 200 and release.json()['version'] == version
    assert release.headers['cache-control'] == 'no-store'
    page = client.get('/update?lang=en&return=/dashboard')
    assert 'Update app' in page.text and 'update.mjs' in page.text
    assert page.headers['cache-control'] == 'no-store'
    for path in ['/static/update.mjs', '/i18n/en.json']:
        assert client.get(path).headers['cache-control'] == 'no-cache'


def test_viewer_sockets_are_capped_per_address(system, monkeypatch):
    from starlette.websockets import WebSocketDisconnect
    monkeypatch.setenv('WS_PER_IP_LIMIT', '2')
    with TestClient(create_app(os.environ['DATABASE_URL'], secure_cookies=False)) as client:
        slug = create(client)['slug']
        with client.websocket_connect(f'/ws/s/{slug}') as one, client.websocket_connect(f'/ws/s/{slug}') as two:
            assert one.receive_json()['revision'] == two.receive_json()['revision']
            with pytest.raises(WebSocketDisconnect) as refused:
                with client.websocket_connect(f'/ws/s/{slug}'):
                    pass
            assert refused.value.code == 1013
        # Closed sockets free their place again.
        with client.websocket_connect(f'/ws/s/{slug}') as again:
            assert again.receive_json()['match_id']


def test_link_preview_is_drawn_once_per_score(system, monkeypatch):
    from score67 import preview
    _, client = system
    slug = create(client)['slug']
    drawn, render = [], preview.render
    monkeypatch.setattr(preview, 'render', lambda *a, **k: drawn.append(1) or render(*a, **k))
    first = client.get(f'/s/{slug}/preview.png?r=1')
    assert first.status_code == 200 and client.get(f'/s/{slug}/preview.png?r=2').content == first.content
    assert len(drawn) == 1
    command(client, slug, 'period_start')
    command(client, slug, 'score', {'team': 'home', 'points': 1})
    assert client.get(f'/s/{slug}/preview.png').content != first.content and len(drawn) == 2
    assert client.get('/preview.png').content == client.get('/preview.png?x=1').content and len(drawn) == 3


def test_a_failing_maintenance_job_is_logged_and_does_not_stop_the_others(system, monkeypatch, caplog):
    import time, score67.app as module
    url = os.environ['DATABASE_URL']
    monkeypatch.setenv('TRASH_INTERVAL_SECONDS', '0.05')
    ran = []
    def broken(db):
        raise ValueError('bad row')
    monkeypatch.setattr(module, 'finish_overdue_matches', broken)
    monkeypatch.setattr(module, 'clean_matches', lambda db: ran.append(1))
    with caplog.at_level('ERROR', logger='score67'), TestClient(create_app(url, secure_cookies=False)) as client:
        for _ in range(40):
            if ran:
                break
            client.get('/health')
            time.sleep(0.05)
    assert ran and 'maintenance job broken failed' in caplog.text


def test_basketball_period_jump_keeps_the_clock_stopped(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    command(client, slug, 'period_start')
    command(client, slug, 'clock_start')
    command(client, slug, 'period_end')
    command(client, slug, 'period_start')
    back = command(client, slug, 'period_set', {'period': 1}).json()
    assert back['period'] == 1 and not back['clock']['running']
    assert command(client, slug, 'clock_start').json()['clock']['running']


def test_late_clock_stop_freezes_where_the_scorer_saw_it():
    from score67.domain import apply, initial_state
    s = initial_state(4, 10, 'basketball')
    s, *_ = apply(s, 'period_start', {}, 1_000)
    s, *_ = apply(s, 'clock_start', {}, 1_000)
    # Tapped at 0:05 played, delivered 20 s later.
    late, event, _ = apply(s, 'clock_stop', {'elapsed_ms': 5_000}, 26_000)
    assert late['clock'] == {**late['clock'], 'elapsed_ms': 5_000, 'running': False} and event['clock_ms'] == 5_000
    # Never beyond what the server clock has run, never before the last start.
    assert apply(s, 'clock_stop', {'elapsed_ms': 90_000}, 26_000)[0]['clock']['elapsed_ms'] == 25_000
    again, *_ = apply(late, 'clock_start', {}, 30_000)
    assert apply(again, 'clock_stop', {'elapsed_ms': 0}, 31_000)[0]['clock']['elapsed_ms'] == 5_000
    assert apply(s, 'clock_stop', {}, 26_000)[0]['clock']['elapsed_ms'] == 25_000


def test_backslash_in_a_title_does_not_break_the_page():
    from score67 import seo
    page = seo.fill('<html lang="en"><title>x</title>', 'en', title='FC A\\B \\1 \\g<0> C:\\Users')
    assert '<title>FC A\\B \\1 \\g&lt;0&gt; C:\\Users</title>' in page


def test_second_yellow_is_a_yellow_red_and_follows_corrections(system):
    _, client = system
    slug = create(client)['slug']
    ids = [str(uuid4()) for _ in range(2)]
    command(client, slug, 'squad', {'team': 'home', 'players': [{'id': i, 'number': str(n), 'name': ''} for n, i in enumerate(ids, 4)]})
    command(client, slug, 'period_start')
    first = command(client, slug, 'yellow_card', {'team': 'home', 'player_id': ids[0], 'second': True}).json()
    assert not first['events'][-1].get('second_yellow') and first['home']['counters'] == {**first['home']['counters'], 'yellow_cards': 1, 'red_cards': 0}
    other = command(client, slug, 'yellow_card', {'team': 'home', 'player_id': ids[1]}).json()
    assert not other['events'][-1].get('second_yellow')
    assert not command(client, slug, 'yellow_card', {'team': 'home'}).json()['events'][-1].get('second_yellow')   # no player named
    second = command(client, slug, 'yellow_card', {'team': 'home', 'player_id': ids[0]}).json()
    assert second['events'][-1]['second_yellow'] and second['home']['counters']['yellow_cards'] == 4 and second['home']['counters']['red_cards'] == 1
    # Taking the second yellow back takes the red back as well.
    undone = command(client, slug, 'yellow_card_correction', {'team': 'home', 'event_id': second['events'][-1]['id']}).json()
    assert undone['home']['counters']['yellow_cards'] == 3 and undone['home']['counters']['red_cards'] == 0
    again = command(client, slug, 'yellow_card', {'team': 'home', 'player_id': ids[0]}).json()
    assert again['events'][-1]['second_yellow'] and again['home']['counters']['red_cards'] == 1


def test_own_goal_counts_for_the_other_team_and_names_the_unlucky_player(system):
    _, client = system
    slug = create(client)['slug']
    player = str(uuid4())
    command(client, slug, 'squad', {'team': 'home', 'players': [{'id': player, 'number': '5', 'name': 'Kim'}]})
    command(client, slug, 'period_start')
    s = command(client, slug, 'score', {'team': 'away', 'points': 1, 'detail': 'own_goal', 'player_id': player}).json()
    assert (s['home']['score'], s['away']['score']) == (0, 1)
    goal = s['events'][-1]
    assert goal['detail'] == 'own_goal' and goal['team'] == 'away' and goal['player']['name'] == 'Kim'
    # A player of the scoring team cannot be the own-goal scorer.
    assert command(client, slug, 'score', {'team': 'home', 'points': 1, 'detail': 'own_goal', 'player_id': player}).status_code == 422
    assert command(client, slug, 'score', {'team': 'home', 'points': 1, 'detail': 'own_goal'}).json()['home']['score'] == 1


def test_football_clock_can_be_paused_and_runs_into_added_time():
    s = initial_state(2, 45)
    s, *_ = apply(s, 'period_start', {}, 0)
    s, *_ = apply(s, 'clock_stop', {}, 10 * 60000)
    assert not s['clock']['running'] and elapsed(s, 30 * 60000) == 10 * 60000
    s, *_ = apply(s, 'clock_start', {}, 30 * 60000)
    assert s['clock']['running'] and elapsed(s, 31 * 60000) == 11 * 60000
    # Stopped in added time, it starts again (no cap at 45:00 as in basketball).
    s, *_ = apply(s, 'clock_stop', {}, 67 * 60000)
    assert elapsed(s, 0) == 47 * 60000
    assert apply(s, 'clock_start', {}, 70 * 60000)[0]['clock']['running']
    with pytest.raises(RuleError):
        apply(s, 'clock_set', {'remaining_ms': 1000}, 0)
    # Ending the half while paused keeps the paused time.
    assert apply(s, 'period_end', {}, 99 * 60000)[0]['clock']['elapsed_ms'] == 47 * 60000


def test_unsportsmanlike_foul_counts_as_player_and_team_foul(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    player = str(uuid4())
    command(client, slug, 'squad', {'team': 'home', 'players': [{'id': player, 'number': '7', 'name': ''}]})
    command(client, slug, 'period_start')
    s = command(client, slug, 'technical_foul', {'team': 'home', 'player_id': player, 'kind': 'unsportsmanlike'}).json()
    foul = s['events'][-1]
    assert foul['kind'] == 'unsportsmanlike' and foul['counts_team'] and s['home']['counters']['team_fouls'] == 1
    assert next(p for p in s['home']['personal_fouls'] if p['id'] == player)['fouls'] == 1
    # Without a named player it is still a team foul (a coach technical is not).
    assert command(client, slug, 'technical_foul', {'team': 'home', 'kind': 'unsportsmanlike'}).json()['home']['counters']['team_fouls'] == 2
    assert command(client, slug, 'technical_foul', {'team': 'home'}).json()['home']['counters']['team_fouls'] == 2
    assert command(client, slug, 'technical_foul', {'team': 'home', 'kind': 'flagrant'}).status_code == 422


def tennis_match(**options):
    s = initial_state(sport='tennis', **options)
    return apply(s, 'period_start', {}, 0)[0]


def test_tennis_match_tiebreak_replaces_the_deciding_set():
    s = tennis_match(tennis_mode='simple', tennis_deciding='match_tiebreak')
    s, *_ = apply(s, 'tennis_set', {'games': [6, 3]}, 0)
    assert not s['tennis']['tiebreak']
    s, *_ = apply(s, 'tennis_set', {'games': [4, 6]}, 0)
    t = s['tennis']
    assert t['tiebreak'] and t['sets'] == [1, 1] and s['period'] == 3 and s['phase'] == 'period_running'
    with pytest.raises(RuleError):
        apply(s, 'tennis_game', {'team': 'home'}, 0)              # no games in a match tie-break
    with pytest.raises(RuleError):
        apply(s, 'tennis_set', {'games': [6, 4]}, 0)              # nor a full set
    with pytest.raises(RuleError):
        apply(s, 'tennis_set', {'games': [1, 0], 'tiebreak': [7, 5]}, 0)   # to 10, not 7
    done, event, _ = apply(s, 'tennis_set', {'games': [1, 0], 'tiebreak': [10, 8]}, 0)
    assert done['phase'] == 'finished' and done['tennis']['winner'] == 0 and event['match_won']
    assert done['tennis']['set_scores'][-1] == {'games': [1, 0], 'tiebreak': [10, 8]}
    # Point by point: first to 10 with two clear, the first server alternates as in any tie-break.
    first = s['tennis']['tiebreak_first']
    for _ in range(9):
        s, *_ = apply(s, 'tennis_point', {'team': 'home'}, 0)
        s, *_ = apply(s, 'tennis_point', {'team': 'away'}, 0)
    assert s['tennis']['points'] == [9, 9] and s['phase'] == 'period_running'
    s, *_ = apply(s, 'tennis_point', {'team': 'away'}, 0)
    assert s['phase'] == 'period_running'                         # 9:10, not two clear
    s, *_ = apply(s, 'tennis_point', {'team': 'away'}, 0)
    assert s['phase'] == 'finished' and s['tennis']['winner'] == 1 and s['tennis']['set_scores'][-1] == {'games': [0, 1], 'tiebreak': [9, 11]}
    assert first in (0, 1)
    # The classic format still plays the third set out.
    classic = tennis_match(tennis_mode='simple')
    classic, *_ = apply(classic, 'tennis_set', {'games': [6, 3]}, 0)
    classic, *_ = apply(classic, 'tennis_set', {'games': [4, 6]}, 0)
    assert not classic['tennis']['tiebreak']
    # Best of five: only the fifth set is replaced.
    five = tennis_match(tennis_mode='simple', tennis_best_of=5, tennis_deciding='match_tiebreak')
    for games in ([6, 3], [3, 6], [6, 3]):
        five, *_ = apply(five, 'tennis_set', {'games': games}, 0)
    assert not five['tennis']['tiebreak']
    five, *_ = apply(five, 'tennis_set', {'games': [3, 6]}, 0)
    assert five['tennis']['tiebreak']


def test_tennis_retirement_names_the_winner():
    s = tennis_match()
    s, *_ = apply(s, 'tennis_point', {'team': 'home'}, 0)
    done, event, _ = apply(s, 'game_end', {'winner': 'away'}, 0)
    assert done['phase'] == 'finished' and done['tennis']['winner'] == 1 and event['retired'] and event['match_won'] and event['team'] == 'away'
    abandoned, event, _ = apply(s, 'game_end', {}, 0)
    assert abandoned['tennis']['winner'] is None and 'match_won' not in event
    with pytest.raises(RuleError):
        apply(s, 'game_end', {'winner': 'nobody'}, 0)


def test_missed_shots_and_possession_are_recorded_for_the_box_score(system):
    _, client = system
    slug = client.post('/api/scoreboards', json={'sport': 'basketball'}).json()['slug']
    player = str(uuid4())
    command(client, slug, 'squad', {'team': 'home', 'players': [{'id': player, 'number': '11', 'name': 'Luke'}]})
    command(client, slug, 'period_start')
    assert command(client, slug, 'possession', {'team': 'home'}).json()['possession'] == 'home'
    for action, data in (('score', {'points': 2}), ('score', {'points': 3}), ('two_missed', {}), ('two_missed', {}), ('three_missed', {}), ('assist', {})):
        command(client, slug, action, {'team': 'home', 'player_id': player, **data})
    s = command(client, slug, 'possession', {'team': 'away'}).json()
    row = next(p for p in s['home']['statistics']['players'] if p['id'] == player)
    assert (row['pts'], row['fgm2'], row['fgx2'], row['fgm3'], row['fgx3'], row['ast']) == (5, 1, 2, 1, 1, 1)
    assert s['possession'] == 'away' and [e['team'] for e in s['events'] if e['type'] == 'possession'] == ['home', 'away']
    # A missed shot can be taken back like any other entry; spectators do not get the misses.
    back = command(client, slug, 'two_missed_correction', {'team': 'home'}).json()
    assert next(p for p in back['home']['statistics']['players'] if p['id'] == player)['fgx2'] == 1
    assert not any(e['type'].startswith(('two_missed', 'three_missed')) for e in state(client, slug)['events'])
    assert command(client, slug, 'three_missed', {'team': 'nobody'}).status_code == 422
