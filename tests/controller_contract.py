#!/usr/bin/env python3
"""Deterministic controller lifecycle; no homelab requests or real downloads."""
import json, os, sqlite3, subprocess, tempfile, threading, time, unittest
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from api_smoke import request, ROOT

class Upstream(BaseHTTPRequestHandler):
    file = None
    grabs = []
    owner = False
    healthy = True
    conflict = False
    active_movie = False
    reject_compact = False
    source_movie = False
    original_state = 'downloading'
    original_size = 15*1024**3
    original_quality = 19
    original_progress = .01
    controls = []
    selected = [1]
    episode_files = {}
    embedded_slim = False
    def log_message(self,*args): pass
    def reply(self,data,status=200):
        body=json.dumps(data).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers();self.wfile.write(body)
    def do_GET(self):
        p=urlparse(self.path).path
        if p=='/api/v3/series/9':return self.reply({'id':9,'title':'Fixture Series','qualityProfileId':1,'originalLanguage':{'id':1},'runtime':45,'monitored':True})
        if p=='/api/v2/torrents/info':return self.reply([{'hash':'c'*40,'name':'Fixture Series','size':self.original_size,'progress':self.original_progress,'state':self.original_state}])
        if p=='/api/v2/torrents/files':return self.reply([{'name':f'Fixture.Series.S01E{n:02}.mkv','size':self.original_size//4,'priority':7 if n in self.selected else 0} for n in (1,2,3,4)])
        if p=='/api/v3/episode':return self.reply([{'id':449+n,'seriesId':9,'seasonNumber':1,'episodeNumber':n} for n in range(1,9)])
        if p.startswith('/api/v3/episode/'):
            return self.reply({'id':int(p.rsplit('/',1)[1]),'seriesId':9,'hasFile':int(p.rsplit('/',1)[1]) in self.episode_files,'episodeFileId':self.episode_files.get(int(p.rsplit('/',1)[1]),{}).get('id',0),'seasonNumber':1,'episodeNumber':int(p.rsplit('/',1)[1])-449})
        if p.startswith('/api/v3/episodefile/'):
            return self.reply(next(x for x in self.episode_files.values() if x['id']==int(p.rsplit('/',1)[1])))
        if p=='/api/v3/parse':
            title=parse_qs(urlparse(self.path).query)['title'][0]
            number=int(title.split('S01E')[1][:2])
            return self.reply({'parsedEpisodeInfo':{'seriesTitle':'Fixture Series','seasonNumber':1,'episodeNumbers':[number]}})
        if p=='/health':return self.reply({'healthy':self.healthy},200 if self.healthy else 503)
        if p.startswith('/api/v3/moviefile/'):
            return self.reply(self.file,200 if self.file and self.file['id']==int(p.rsplit('/',1)[1]) else 404)
        if p=='/api/v3/movie/48':return self.reply({'id':48,'title':'Fixture','qualityProfileId':1,'originalLanguage':{'id':1},'monitored':True,'hasFile':self.file is not None,'movieFile':({k:v for k,v in self.file.items() if k not in ['customFormats','customFormatScore']} if self.embedded_slim and self.file else self.file or {})})
        profiles=[{'id':id,'name':name,'upgradeAllowed':True,'cutoff':19,'cutoffFormatScore':1000,'minFormatScore':0,'minUpgradeFormatScore':1,'formatItems':[{'format':1,'score':20},{'format':2,'score':score}],'items':[{'quality':{'id':7,'name':'Bluray-1080p'},'allowed':id!=3},{'quality':{'id':19,'name':'Bluray-2160p'},'allowed':id!=2}]} for id,name,score in [(1,'Fixture profile',1000),(2,'Compact 1080p',1000),(3,'Final 4K',2000)]]
        if p=='/api/v3/qualityprofile':return self.reply(profiles)
        if p.startswith('/api/v3/qualityprofile/'):
            profile=next((x for x in profiles if x['id']==int(p.rsplit('/',1)[1])),None)
            return self.reply(profile,200 if profile else 404)
        if p=='/api/v3/release':
            releases=[{'guid':g,'title':g,'indexerId':1,'size':size,'seeders':30,'quality':{'quality':{'id':qid,'name':name,'resolution':res}},'languages':[{'id':1}],'customFormatScore':score,'customFormats':[{'id':1 if qid==7 else 2}],'approved':not (self.reject_compact and g=='compact'),'rejected':self.reject_compact and g=='compact','temporarilyRejected':False,'downloadAllowed':True,'protocol':'torrent','infoHash':h*40} for g,size,qid,name,res,score,h in [('compact',2*1024**3,7,'Bluray-1080p',1080,20,'a'),('upgrade',15*1024**3,19,'Bluray-2160p',2160,1000,'b')]]
            eid=parse_qs(urlparse(self.path).query).get('episodeId',[None])[0]
            if eid:
                for item in releases:
                    item.update(guid=item['guid']+'-'+eid,episodeNumbers=[int(eid)-449],seasonNumber=1,seriesId=9)
                    if item['quality']['quality']['id']==7:item['size']=700*1024**2
            return self.reply(releases)
        if p=='/api/v3/queue':return self.reply({'totalRecords':8,'records':([{'movieId':48,'downloadId':'d'*40}] if self.active_movie else []) + ([{'movieId':48,'downloadId':'c'*40,'quality':{'quality':{'id':self.original_quality,'resolution':2160 if self.original_quality==19 else 1080}},'customFormatScore':1000 if self.original_quality==19 else 20,'customFormats':[{'id':2 if self.original_quality==19 else 1}]}] if self.source_movie else []) + [{'seriesId':9,'episodeId':449+n,'downloadId':'c'*40,'quality':{'quality':{'id':19,'resolution':2160}},'customFormatScore':1000,'customFormats':[{'id':2}]} for n in range(1,9)]})
        return self.reply({},404)
    def do_POST(self):
        p=self.path; raw=self.rfile.read(int(self.headers.get('Content-Length','0')))
        if p in ['/api/v2/torrents/stop','/api/v2/torrents/start']:
            type(self).controls.append(p.rsplit('/',1)[1]);type(self).original_state='stoppedDL' if p.endswith('/stop') else 'downloading';return self.reply({})
        body=json.loads(raw)
        if p=='/ownership/claim':
            if self.conflict:return self.reply({},409)
            type(self).owner=True; return self.reply({'token':'private-owner-token'})
        if p=='/ownership/release':type(self).owner=False;return self.reply({'released':True})
        if p=='/api/v3/release':type(self).grabs.append(body['guid']);return self.reply({})
        return self.reply({},404)

class ControllerContract(unittest.TestCase):
    def setUp(self):
        Upstream.file=None;Upstream.grabs=[];Upstream.owner=False;Upstream.healthy=True;Upstream.conflict=False;Upstream.active_movie=False;Upstream.reject_compact=False;Upstream.source_movie=False;Upstream.original_state='downloading';Upstream.original_size=15*1024**3;Upstream.original_quality=19;Upstream.original_progress=.01;Upstream.controls=[];Upstream.selected=[1];Upstream.episode_files={};Upstream.embedded_slim=False
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Upstream)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.temp=tempfile.TemporaryDirectory(prefix='prontarr-controller-');self.folder=Path(self.temp.name)
        url=f'http://127.0.0.1:{self.server.server_port}'
        config={'radarr':{'url':url,'api_key':'fixture-secret'},'sonarr':{'url':url,'api_key':'fixture-secret'},'qbittorrent':{'url':url},'coordinator':{'url':url},'vpn_health':{'url':url},'execution':{'enabled':True,'allowed_movie_ids':[48]}}
        path=self.folder/'connections.json';path.write_text(json.dumps(config));path.chmod(0o600)
        self.env=os.environ|{'PRONTARR_DB':str(self.folder/'db.sqlite'),'PRONTARR_CONNECTIONS':str(path)}
        self.log=tempfile.TemporaryFile();self.process=None;self.start()
    def start(self):
        self.process=subprocess.Popen([os.environ.get('PRONTARR_TEST_BINARY', str(ROOT/'zig-out/bin/prontarr'))],cwd=ROOT,env=self.env,stdout=self.log,stderr=self.log)
        for _ in range(100):
            if self.process.poll() is not None:self.log.seek(0);raise AssertionError(self.log.read().decode())
            try:
                if request('/api/health')[0]==200:return
            except OSError:pass
            time.sleep(.05)
        raise AssertionError('server startup timeout')
    def stop(self):
        if self.process and self.process.poll() is None:self.process.terminate();self.process.wait(timeout=5)
    def tearDown(self):
        self.stop();self.server.shutdown();self.server.server_close();self.log.close();self.temp.cleanup()
    def wait_stage(self,id,stage):
        for _ in range(100):
            status,data,_=request(f'/api/jobs/{id}')
            if data['job']['stage']==stage:return data
            time.sleep(.1)
        raise AssertionError(data)
    def plan(self):
        status,data,_=request('/api/jobs',{'target':{'app':'radarr','media_id':48}});self.assertEqual(status,202)
        self.wait_stage(data['id'],'ready');return data['id']
    def test_full_lifecycle_restart_idempotency_and_redaction(self):
        id=self.plan();status,again,_=request('/api/jobs',{'target':{'app':'radarr','media_id':48}});self.assertEqual(again['id'],id)
        self.assertEqual(request(f'/api/jobs/{id}/start',{})[0],202)
        self.wait_stage(id,'compact')
        for _ in range(50):
            if Upstream.grabs:break
            time.sleep(.1)
        self.assertEqual(Upstream.grabs,['compact']);self.assertTrue(Upstream.owner)
        self.stop()
        with sqlite3.connect(self.folder/'db.sqlite') as db:
            state=json.loads(db.execute('SELECT state FROM live_jobs WHERE id=?',(id,)).fetchone()[0])
            state['stage']='completed'
            for n in range(150):db.execute('INSERT INTO live_jobs(request_key,state) VALUES(?,?)',(f'past-{n}',json.dumps(state)))
        self.start();time.sleep(2.2);self.assertEqual(Upstream.grabs,['compact'])
        Upstream.file={'id':10,'quality':{'quality':{'id':7}},'customFormatScore':20}
        self.wait_stage(id,'upgrading')
        for _ in range(50):
            if len(Upstream.grabs)==2:break
            time.sleep(.1)
        self.assertEqual(Upstream.grabs,['compact','upgrade'])
        Upstream.file={'id':11,'quality':{'quality':{'id':19}},'customFormatScore':1000}
        final=self.wait_stage(id,'completed');self.assertFalse(Upstream.owner)
        encoded=json.dumps(final)
        for secret in ['private-owner-token','fixture-secret','indexer_id','"guid"']:self.assertNotIn(secret,encoded)
        self.assertEqual((self.folder/'db.sqlite').stat().st_mode&0o777,0o600)
    def test_vpn_failure_prevents_claim_and_grab_then_cancel(self):
        id=self.plan();Upstream.healthy=False;request(f'/api/jobs/{id}/start',{});time.sleep(2.3)
        self.assertEqual(Upstream.grabs,[]);self.assertFalse(Upstream.owner)
        Upstream.healthy=True
        self.wait_stage(id,'compact')
        recovered=request(f'/api/jobs/{id}')[1]
        self.assertIsNone(recovered['job']['error_code'])
        request(f'/api/jobs/{id}/cancel',{});self.wait_stage(id,'cancelled')
        self.assertFalse(Upstream.owner)
    def test_ownership_conflict_prevents_grab(self):
        id=self.plan();Upstream.conflict=True;request(f'/api/jobs/{id}/start',{})
        self.wait_stage(id,'review');self.assertEqual(Upstream.grabs,[])
    def test_profile_choices_filter_each_stage_and_reanalysis_adopts_changes(self):
        status,data,_=request('/api/profiles')
        self.assertEqual(status,200)
        self.assertEqual([p['name'] for p in data['services'][0]['items']],['Fixture profile','Compact 1080p','Final 4K'])
        policy=request('/api/policy')[1]
        policy['radarr_profiles']={'initial_id':2,'final_id':3}
        self.assertEqual(request('/api/policy',policy,'PUT')[0],200)
        id=self.plan();report=request(f'/api/jobs/{id}')[1]['report']
        self.assertEqual(report['initial_profile_name'],'Compact 1080p')
        self.assertEqual(report['profile_name'],'Final 4K')
        selected=next(x for x in report['candidates'] if x['id']==report['upgrade_candidate_id'])
        self.assertEqual(selected['format_score'],2000)
        policy['radarr_profiles']={'initial_id':3,'final_id':1}
        self.assertEqual(request('/api/policy',policy,'PUT')[0],200)
        self.assertEqual(request(f'/api/jobs/{id}')[1]['report']['initial_profile_name'],'Compact 1080p')
        self.assertEqual(request(f'/api/jobs/{id}/analyze',{})[0],200)
        report=self.wait_stage(id,'ready')['report']
        self.assertEqual(report['initial_profile_name'],'Final 4K')
        self.assertIsNone(report['compact_candidate_id'])
        self.assertEqual(Upstream.grabs,[])
        self.stop();self.start()
        self.assertEqual(request('/api/policy')[1]['radarr_profiles']['initial_id'],3)

    def test_selected_profile_never_overrides_native_rejection(self):
        policy=request('/api/policy')[1]
        policy['radarr_profiles']={'initial_id':2,'final_id':3}
        self.assertEqual(request('/api/policy',policy,'PUT')[0],200)
        Upstream.reject_compact=True
        id=self.plan();report=request(f'/api/jobs/{id}')[1]['report']
        self.assertIsNone(report['compact_candidate_id'])
        self.assertEqual(request(f'/api/jobs/{id}/start',{})[0],409)
        self.assertEqual(Upstream.grabs,[])

    def test_missing_and_invalid_profile_ids_are_not_saved(self):
        policy=request('/api/policy')[1]
        for id in (-1,999):
            policy['radarr_profiles']={'initial_id':id,'final_id':None}
            self.assertEqual(request('/api/policy',policy,'PUT')[0],400)
        self.assertIsNone(request('/api/policy')[1]['radarr_profiles']['initial_id'])

    def test_existing_native_download_prevents_duplicate_acquisition(self):
        id=self.plan();Upstream.active_movie=True
        request(f'/api/jobs/{id}/start',{})
        detail=self.wait_stage(id,'review')
        self.assertEqual(detail['job']['error_code'],'ExistingDownloadNeedsAnalysis')
        self.assertEqual(Upstream.grabs,[]);self.assertFalse(Upstream.owner)

    def standalone(self, automatic=False):
        self.stop()
        path=self.folder/'connections.json';config=json.loads(path.read_text())
        config.pop('coordinator',None)
        config['execution'].update(standalone=True,automatic=automatic,allow_all_movies=True,allow_all_series=not automatic)
        path.write_text(json.dumps(config));self.start()

    def original_plan(self):
        status,data,_=request('/api/jobs',{'target':{'app':'radarr','media_id':48,'original_hash':'c'*40}})
        self.assertEqual(status,202);self.wait_stage(data['id'],'ready');return data['id']

    def test_standalone_original_upgrade_is_paused_and_resumed_without_regrab(self):
        self.standalone();Upstream.source_movie=True
        id=self.original_plan();self.assertEqual(request(f'/api/jobs/{id}/start',{})[0],202)
        self.wait_stage(id,'compact');time.sleep(.3)
        self.assertEqual(Upstream.controls,['stop']);self.assertEqual(Upstream.grabs,['compact'])
        self.stop();self.start();time.sleep(2.3)
        self.assertEqual(Upstream.grabs,['compact'])
        Upstream.file={'id':10,'quality':{'quality':{'id':7}},'customFormatScore':20}
        self.wait_stage(id,'upgrading');time.sleep(.2)
        self.assertIn('start',Upstream.controls);self.assertEqual(Upstream.grabs,['compact'])
        Upstream.file={'id':11,'quality':{'quality':{'id':19}},'customFormatScore':1000}
        self.wait_stage(id,'completed')
        with sqlite3.connect(self.folder/'db.sqlite') as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM live_ownership').fetchone()[0],0)
        self.assertFalse(Upstream.owner)

    def test_standalone_adopts_existing_compact_without_pausing_or_duplicate(self):
        self.standalone();Upstream.source_movie=True;Upstream.original_size=2*1024**3;Upstream.original_quality=7;Upstream.original_progress=.7
        id=self.original_plan();request(f'/api/jobs/{id}/start',{});self.wait_stage(id,'compact')
        self.assertEqual(Upstream.controls,[]);self.assertEqual(Upstream.grabs,[])
        Upstream.file={'id':10,'quality':{'quality':{'id':7}},'customFormatScore':20}
        self.wait_stage(id,'upgrading');time.sleep(.2)
        self.assertEqual(Upstream.grabs,['upgrade']);self.assertEqual(Upstream.controls,[])

    def test_standalone_manual_pause_and_existing_progress_are_preserved(self):
        for state,progress,reason in [('stoppedDL',.01,'RespectManualPause'),('downloading',.5,'RespectExistingProgress')]:
            self.standalone();Upstream.source_movie=True;Upstream.original_state=state;Upstream.original_progress=progress
            id=self.original_plan();request(f'/api/jobs/{id}/start',{})
            detail=self.wait_stage(id,'review');self.assertEqual(detail['job']['error_code'],reason)
            self.assertEqual(Upstream.controls,[]);self.assertEqual(Upstream.grabs,[])
            request(f'/api/jobs/{id}/cancel',{});self.wait_stage(id,'cancelled')
            request(f'/api/jobs/{id}/analyze',{});self.wait_stage(id,'ready')

    def test_automatic_intake_is_durable_and_uses_no_legacy_coordinator(self):
        Upstream.source_movie=True;self.standalone(automatic=True)
        for _ in range(100):
            jobs=request('/api/jobs')[1]['items']
            if jobs and jobs[0]['stage']=='compact':break
            time.sleep(.1)
        self.assertEqual(len(jobs),1);self.assertEqual(jobs[0]['stage'],'compact')
        self.assertEqual(Upstream.grabs,['compact']);self.assertFalse(Upstream.owner)
        self.stop();self.start();time.sleep(2.3)
        self.assertEqual(len(request('/api/jobs')[1]['items']),1);self.assertEqual(Upstream.grabs,['compact'])

    def test_pack_waits_for_all_compact_imports_before_resuming_original(self):
        self.standalone();Upstream.selected=[1,2]
        status,data,_=request('/api/jobs',{'target':{'app':'sonarr','media_id':9,'original_hash':'c'*40}})
        self.assertEqual(status,202);id=data['id'];self.wait_stage(id,'ready')
        self.assertEqual(request(f'/api/jobs/{id}/start',{})[0],202);self.wait_stage(id,'compact');time.sleep(.2)
        self.assertEqual(Upstream.grabs,['compact-450','compact-451']);self.assertEqual(Upstream.controls,['stop'])
        Upstream.episode_files[450]={'id':10,'quality':{'quality':{'id':7}},'customFormatScore':20}
        time.sleep(2.3);self.assertEqual(request(f'/api/jobs/{id}')[1]['job']['stage'],'compact');self.assertEqual(Upstream.controls,['stop'])
        Upstream.episode_files[451]={'id':11,'quality':{'quality':{'id':7}},'customFormatScore':20}
        self.wait_stage(id,'upgrading');time.sleep(.2);self.assertIn('start',Upstream.controls)
        self.assertEqual(Upstream.grabs,['compact-450','compact-451'])
        Upstream.episode_files[450]={'id':20,'quality':{'quality':{'id':19}},'customFormatScore':1000}
        time.sleep(2.3);self.assertEqual(request(f'/api/jobs/{id}')[1]['job']['stage'],'upgrading')
        Upstream.episode_files[451]={'id':21,'quality':{'quality':{'id':19}},'customFormatScore':1000}
        self.wait_stage(id,'completed')

    def test_cancelling_takeover_resumes_only_the_original_and_keeps_compact(self):
        self.standalone();Upstream.source_movie=True
        id=self.original_plan();request(f'/api/jobs/{id}/start',{});self.wait_stage(id,'compact');time.sleep(.2)
        request(f'/api/jobs/{id}/cancel',{});self.wait_stage(id,'cancelled')
        self.assertEqual(Upstream.controls,['stop','start']);self.assertEqual(Upstream.grabs,['compact'])

    def test_dedicated_movie_file_restores_formats_omitted_from_movie_resource(self):
        Upstream.file={'id':55,'quality':{'quality':{'id':7}},'customFormats':[{'id':1}],'customFormatScore':20}
        Upstream.embedded_slim=True
        id=self.plan();report=request(f'/api/jobs/{id}')[1]['report']
        self.assertEqual(report['files'][0]['format_score'],20)
        request(f'/api/jobs/{id}/start',{});self.wait_stage(id,'upgrading');time.sleep(.2)
        self.assertEqual(Upstream.grabs,['upgrade'])

    def test_pack_scope_uses_file_priorities_not_eight_queue_rows(self):
        status,data,_=request('/api/jobs',{'target':{'app':'sonarr','media_id':9,'original_hash':'c'*40}})
        self.assertEqual(status,202)
        detail=self.wait_stage(data['id'],'ready')
        scope=detail['report']['scope']
        self.assertTrue(scope['verified'])
        self.assertEqual(scope['contained_episode_ids'],[450,451,452,453])
        self.assertEqual(scope['selected_episode_ids'],[450])
        self.assertEqual(scope['absent_queue_episode_ids'],[454,455,456,457])
        self.assertEqual(detail['job']['target']['episode_ids'],[450])

    def test_whitelist_and_second_process_lock(self):
        status,data,_=request('/api/jobs',{'target':{'app':'radarr','media_id':49}})
        self.assertEqual(request(f'/api/jobs/{data["id"]}/start',{})[0],409)
        other=subprocess.run([os.environ.get('PRONTARR_TEST_BINARY', str(ROOT/'zig-out/bin/prontarr'))],cwd=ROOT,env=self.env,capture_output=True,timeout=5)
        self.assertNotEqual(other.returncode,0);self.assertIn(b'ControllerAlreadyRunning',other.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
