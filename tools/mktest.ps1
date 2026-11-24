param([switch]$NoMock)
$d=Split-Path -Parent $MyInvocation.MyCommand.Path
$src=[IO.File]::ReadAllText((Join-Path $d "..\src\doran-village.html"),[Text.Encoding]::UTF8)
$
$i=$src.LastIndexOf('})();')
$src=$src.Substring(0,$i)+$hook+$src.Substring($i+5)
$head='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><style>body{margin:0;font:14px system-ui}[hidden]{display:none!important}img{max-width:100%}</style><script>(function(){var hs=[],on={},mine={};var me={peer:"p1",by:null,isMe:true,sameTab:true,kind:"viewer",guest:false,presence:mine,updatedAt:0};var fr={peer:"p2",by:null,isMe:false,sameTab:false,kind:"viewer",guest:false,presence:{n:"Mina",c:"#3f8fc4",x:7,y:12,d:2,s:0,say:"hello!",st:1},updatedAt:0};var list=[me,fr];function fire(){hs.forEach(function(h){h({peers:list,joined:list,left:[],updated:[]})})}var room={presence:function(p){Object.assign(mine,p);window.__pres=mine;return Promise.resolve()},onPeers:function(h){hs.push(h);setTimeout(fire,50);return function(){}},peers:function(){return list},emit:function(t,d){window.__emit=[t,d];return Promise.resolve()},on:function(t,h){(on[t]=on[t]||[]).push(h);return function(){}},connected:function(){return true}};window.__room={fr:fr,fire:fire,on:on,list:list};window.claude={use:function(n){return Promise.resolve(n==="room"?room:null)}}})();</script></head><body>'
[IO.File]::WriteAllText("$d\test.html",$head+$src+'</body></html>',(New-Object Text.UTF8Encoding $false))
# p2p.html: window.claude가 없는 판(GitHub 페이지와 같은 조건). 방 이름으로 같이 하기 시험용
$head2='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><style>body{margin:0;font:14px system-ui}[hidden]{display:none!important}img{max-width:100%}</style></head><body>'
[IO.File]::WriteAllText("$d\p2p.html",$head2+$src+'</body></html>',(New-Object Text.UTF8Encoding $false))
"ok"
