from fastapi.testclient import TestClient
from test_score67 import system, create, state, command


def test_disconnect_checks_connection_authority_and_stays_disconnected(system):
    app, client = system
    device = TestClient(app)
    reg = device.post('/api/display/register', json={'device_key': 'disconnect-test-device-key-1234567890'}).json()
    board = create(client)
    slug = board['slug']
    other = create(client)['slug']
    info = client.post(f'/api/s/{slug}/displays', json={'code': reg['code']}).json()
    panel = info['id']
    endpoint = f'/api/displays/{panel}/disconnect'
    body = {'expected_board': slug, 'expected_match': state(client, slug)['match_id']}
    assert info['match_id'] == body['expected_match']
    assert info['match_label'] == 'Home – Guest'
    assert TestClient(app).post(endpoint, json=body).status_code == 401
    # A different scoreboard was assigned while the dialog was open.
    client.put(f'/api/displays/{panel}', json={'board': other})
    assert client.post(endpoint, json=body).status_code == 409
    assert client.get('/api/displays').json()['displays'][0]['board'] == other
    client.put(f'/api/displays/{panel}', json={'board': slug})
    # A new match on the same scoreboard must also invalidate the confirmation.
    command(client, slug, 'game_end')
    new = command(client, slug, 'new_match').json()
    assert client.post(endpoint, json=body).status_code == 409
    body['expected_match'] = new['match_id']
    assert client.post(endpoint, json=body).json() == {'ok': True}
    current = client.get('/api/displays').json()['displays'][0]
    assert current['board'] is None and current['follow'] is False
    assert client.post(f'/api/s/{slug}/displays/follow', json={}).json()['displays'][0]['board'] is None
    assert client.post(endpoint, json=body).status_code == 409
    assert client.put(f'/api/s/{slug}/displays/{panel}', json={}).json()['board'] == slug
    # A controller without panel management can disconnect their own game.
    coach = TestClient(app)
    assert coach.post(f'/api/s/{slug}/admin/claim', json={'pin': board['pin']}).status_code == 200
    assert coach.post(endpoint, json=body).status_code == 200
