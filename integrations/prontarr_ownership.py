"""Exclusive durable ownership gate for the legacy fast-first coordinator.

Caller must hold the same RLock around gate operations and legacy processing.
No lease expiry: a crashed client cannot cause two concurrent controllers.
"""
import hmac
import json
import os
from pathlib import Path
import secrets

class Conflict(Exception):
    pass

class Ownership:
    def __init__(self, path):
        self.path = Path(path)
        self.owners = json.loads(self.path.read_text()) if self.path.exists() else {}

    def owns(self, app, media_id):
        return f'{app}:{media_id}' in self.owners

    def save(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = self.path.with_suffix('.tmp')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(self.owners, stream)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(self.path)
        directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(directory)
        finally: os.close(directory)

    def update(self, body, legacy_state, release=False):
        app, media_id, job_id = body.get('app'), body.get('media_id'), body.get('job_id')
        if app not in ('radarr','sonarr') or type(media_id) is not int or media_id <= 0 or type(job_id) is not int or job_id <= 0:
            raise ValueError('Invalid ownership scope')
        key = f'{app}:{media_id}'
        existing = self.owners.get(key)
        if release:
            if not existing:return {'released': True}
            supplied=body.get('token')
            if existing['job_id'] != job_id or not isinstance(supplied,str) or not hmac.compare_digest(existing['token'], supplied):
                raise Conflict('Ownership belongs to another job')
            del self.owners[key]
            self.save()
            return {'released': True}
        if existing:
            if existing['job_id'] != job_id:raise Conflict('Another job owns this scope')
            return {'token':existing['token']}
        if any(item['app']==app and str(item['mid'])==str(media_id) for item in legacy_state.values()):
            raise Conflict('Legacy controller already owns this scope')
        self.owners[key]={'job_id':job_id,'token':secrets.token_urlsafe(32)}
        self.save()
        return {'token':self.owners[key]['token']}
