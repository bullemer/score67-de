"""Ephemeral browser presence for the single-worker scoreboard server.

No IP addresses or viewing history are retained. Entries expire after 65 seconds.
"""
import time


class Audience:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.viewers = {}

    def count(self, slug, viewer=None):
        now = self.clock()
        self.viewers = {key: seen for key, seen in self.viewers.items() if now - seen < 65}
        if viewer:
            self.viewers[(slug, viewer)] = now
        return sum(board == slug for board, _ in self.viewers)
