from score67.audience import Audience


def test_presence_deduplicates_expires_and_isolates_boards():
    now = [0]
    audience = Audience(clock=lambda: now[0])
    assert audience.count('one') == 0
    assert audience.count('one', 'browser-a') == 1
    assert audience.count('one', 'browser-a') == 1
    assert audience.count('one', 'browser-b') == 2
    assert audience.count('two', 'browser-a') == 1
    now[0] = 40
    assert audience.count('one', 'browser-a') == 2
    now[0] = 65
    assert audience.count('one') == 1
    assert audience.count('two') == 0
    now[0] = 105
    assert audience.count('one') == 0
    assert audience.viewers == {}
