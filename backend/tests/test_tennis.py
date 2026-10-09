from copy import deepcopy
import pytest
from score67.domain import initial_state, apply, RuleError
from score67.tennis import point_labels
from test_score67 import system, state, command


def start(**kwargs):
    return apply(initial_state(sport='tennis', **kwargs), 'period_start', {}, 1000)[0]


def points(s, side, count):
    for _ in range(count):
        s = apply(s, 'tennis_point', {'team': side}, 2000)[0]
    return s


def games(s, side, count):
    for _ in range(count):
        s = apply(s, 'tennis_game', {'team': side}, 2000)[0] if s['tennis']['mode'] == 'simple' else points(s, side, 4)
    return s


def test_points_deuce_advantage_and_service():
    s = start()
    assert not s['clock']['enabled']
    for label in ('15', '30', '40'):
        s = points(s, 'home', 1)
        assert point_labels(s['tennis']) == [label, '0']
    s = points(s, 'away', 3)
    assert point_labels(s['tennis']) == ['40', '40']
    s = points(s, 'home', 1)
    assert point_labels(s['tennis']) == ['AD', '40']
    s = points(s, 'away', 1)
    assert point_labels(s['tennis']) == ['40', '40']
    s = points(s, 'away', 2)
    assert s['tennis']['games'] == [0, 1] and s['tennis']['server'] == 1
    assert point_labels(s['tennis']) == ['0', '0']


@pytest.mark.parametrize('mode', ['simple', 'detailed'])
@pytest.mark.parametrize('category,best_of', [('women', 3), ('men', 3), ('men', 5)])
def test_full_match_auto_win_and_undo(mode, category, best_of):
    s = start(tennis_mode=mode, tennis_category=category, tennis_best_of=best_of)
    wins = best_of // 2 + 1
    s = games(s, 'home', 6 * wins - 1)
    assert s['phase'] == 'period_running'
    action = 'tennis_game' if mode == 'simple' else 'tennis_point'
    if mode == 'detailed':
        s = points(s, 'home', 3)
    before = deepcopy(s)
    s, event, undo = apply(s, action, {'team': 'home'}, 5000)
    assert s['phase'] == 'finished' and s['tennis']['sets'] == [wins, 0]
    assert event['match_won'] and len(s['tennis']['set_scores']) == wins
    with pytest.raises(RuleError):
        apply(s, action, {'team': 'away'}, 6000)
    s.update(undo)
    assert s == before


def test_seven_five_set_and_tiebreak_service():
    s = start(tennis_mode='simple')
    s = games(games(s, 'home', 5), 'away', 5)
    s = games(s, 'home', 1)
    assert s['tennis']['sets'] == [0, 0]
    s = games(s, 'home', 1)
    assert s['tennis']['set_scores'] == [{'games': [7, 5]}]
    s = games(games(s, 'home', 5), 'away', 5)
    s = games(games(s, 'home', 1), 'away', 1)
    assert s['tennis']['tiebreak']
    first = s['tennis']['server']
    s = points(s, 'home', 1)
    assert s['tennis']['server'] == 1 - first
    s = points(s, 'away', 1)
    assert s['tennis']['server'] == 1 - first
    s = points(s, 'home', 1)
    assert s['tennis']['server'] == first
    s = points(points(s, 'home', 4), 'away', 5)
    assert s['tennis']['points'] == [6, 6]
    s = points(s, 'home', 1)
    assert s['phase'] != 'finished'
    s = points(s, 'home', 1)
    assert s['phase'] == 'finished'
    assert s['tennis']['set_scores'][-1] == {'games': [7, 6], 'tiebreak': [8, 6]}
    assert s['tennis']['server'] == 1 - first


def test_ten_point_deciding_set_tiebreak():
    s = start(tennis_mode='simple', tennis_final_tiebreak=10)
    s = games(games(s, 'home', 6), 'away', 6)
    s = games(games(s, 'home', 5), 'away', 5)
    s = games(games(s, 'home', 1), 'away', 1)
    s = points(s, 'home', 7)
    assert s['phase'] != 'finished'
    s = points(points(s, 'away', 9), 'home', 3)
    assert s['phase'] != 'finished'
    s = points(s, 'home', 1)
    assert s['phase'] == 'finished'
    assert s['tennis']['set_scores'][-1]['tiebreak'] == [11, 9]


@pytest.mark.parametrize('score,tb', [([6, 5], None), ([7, 4], None), ([6, 6], None), ([7, 6], [7, 6]), ([7, 6], [5, 7]), ([6, 0], [7, 0]), ([7, 6], [8, 5])])
def test_invalid_set_results(score, tb):
    with pytest.raises(RuleError):
        apply(start(tennis_mode='simple'), 'tennis_set', {'games': score, 'tiebreak': tb}, 2000)


def test_set_entry_and_format_validation():
    s = start(tennis_mode='simple')
    s = apply(s, 'tennis_set', {'games': [6, 4]}, 2000)[0]
    s = apply(s, 'tennis_set', {'games': [7, 6], 'tiebreak': [7, 5]}, 3000)[0]
    assert s['phase'] == 'finished'
    for action, data in [('score', {'team': 'home', 'points': 1}), ('period_end', {}), ('settings', {'tennis_best_of': 5}), ('settings', {'clock_enabled': True})]:
        with pytest.raises(RuleError):
            apply(start(), action, data, 2000)
    for data in [{'tennis_best_of': 4}, {'tennis_mode': 'other'}, {'tennis_category': 'other'}]:
        with pytest.raises(RuleError):
            apply(initial_state(sport='tennis'), 'settings', data, 2000)


def test_tennis_api_quickstart_undo_rematch_dashboard_and_viewer(system):
    _, client = system
    assert 'data-quickstart-sport="tennis"' in client.get('/').text
    result = client.post('/api/scoreboards', json={'sport': 'tennis', 'tennis_category': 'men', 'tennis_best_of': 5, 'tennis_mode': 'simple'})
    assert result.status_code == 201, result.text
    slug = result.json()['slug']
    assert command(client, slug, 'period_start').status_code == 200
    for score in ([6, 3], [6, 4], [7, 6]):
        response = command(client, slug, 'tennis_set', {'games': score})
        assert response.status_code == 200, response.text
    s = response.json()
    assert s['phase'] == 'finished' and s['home']['score'] == 3
    assert s['home']['period_scores'] == [6, 6, 7]
    assert client.get('/api/live').json()['finished'][0]['match_id'] == s['match_id']
    assert client.get('/api/dashboard').json()['boards'][0]['matches'][0]['tennis']['best_of'] == 5
    assert 'id="tennis-score"' in client.get(f'/s/{slug}').text
    assert 'id="tennis-score"' in client.get(f'/s/{slug}/overlay').text
    undone = command(client, slug, 'undo', {'event_id': s['events'][-1]['id']}).json()
    assert undone['phase'] == 'period_running' and undone['home']['score'] == 2
    assert command(client, slug, 'tennis_set', {'games': [6, 1]}).status_code == 200
    new = command(client, slug, 'new_match').json()
    assert new['tennis']['best_of'] == 5 and new['tennis']['mode'] == 'simple'
    assert new['home']['score'] == 0 and new['tennis']['set_scores'] == []
    assert client.post('/api/scoreboards', json={'sport': 'tennis', 'tennis_best_of': 4}).status_code == 422


def test_tennis_saved_board_new_match_format_and_point_idempotency(system):
    from uuid import uuid4
    _, client = system
    assert 'tennis' in [sport['id'] for sport in client.get('/api/sports').json()]
    result = client.post('/api/scoreboards', json={'sport': 'tennis'}).json()
    slug = result['slug']
    created = client.post(f'/api/s/{slug}/matches', json={
        'command_id': str(uuid4()), 'sport': 'tennis', 'home': 'Alice', 'away': 'Bea',
        'tennis_category': 'women', 'tennis_best_of': 3, 'tennis_mode': 'detailed', 'tennis_final_tiebreak': 10})
    assert created.status_code == 201, created.text
    match = created.json()['match_id']
    game = client.get(f'/api/s/{slug}/matches/{match}/control-state').json()
    assert game['tennis']['final_tiebreak'] == 10
    assert command(client, slug, 'activate', current=game).status_code == 200
    assert command(client, slug, 'period_start').status_code == 200
    current = state(client, slug)
    identifier = str(uuid4())
    for _ in range(2):
        scored = command(client, slug, 'tennis_point', {'team': 'away'}, current=current, command_id=identifier)
        assert scored.status_code == 200, scored.text
        assert scored.json()['tennis']['point_labels'] == ['0', '15']
    assert command(client, slug, 'score', {'team': 'home', 'points': 1}).status_code == 422
