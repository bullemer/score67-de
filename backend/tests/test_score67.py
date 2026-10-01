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

from score67.app import create_app
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
    assert client.post('/api/scoreboards', json={'sport': 'basketball'}).status_code == 422
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
    updated = command(client, slug, 'settings', {'home': {'name': 'FC Hafen', 'short': 'HAFEN', 'color': '#FACC15'}}).json()
    assert updated['home']['name'] == 'FC Hafen' and updated['home']['color'] == '#facc15'
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
