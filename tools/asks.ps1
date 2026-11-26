# 공개 주소(GitHub 페이지 등)에서 "문의"로 보낸 글을 읽는 스크립트. PowerShell 7 이상.
#
# 게임은 문의 글을 운영자 공개 열쇠로 잠가 공개 Nostr 중계 서버에 올린다(원본의 ASK_PUB, ASK_RELAYS, ASK_KIND).
# 이 스크립트는 운영자 열쇠 파일로 그 글을 풀어서 보여 준다. -Done을 주지 않으면 읽기만 하고 아무것도 올리지 않는다.
#
#   ./tools/asks.ps1            받은 글을 표로
#   ./tools/asks.ps1 -Json      받은 글을 JSON으로 (다른 도구가 읽을 때)
#   ./tools/asks.ps1 -Done 0e087129              그 글(id 앞 여덟 자)을 "처리함"으로 표시 (게임의 "처리함"과 같은 글을 중계 서버에 올린다)
#   ./tools/asks.ps1 -Done 0e087129 -Reply "…"   답글을 달면서 처리함으로 표시 (보낸 사람만 풀 수 있게 잠가 올린다)
#   ./tools/asks.ps1 -NewKey    운영자 열쇠를 새로 만들어 파일에 적고 공개 열쇠만 보여 준다 (원본의 ASK_PUB에 넣는다)
#
# 운영자 열쇠 파일은 저장소 바깥에 둔다(기본: 저장소 폴더의 바로 위). 절대 저장소에 넣지 않는다.
# 글이 안 보일 때는 -Verbose를 붙이면 서버마다 받은 수와 못 푼 까닭이 나온다.
[CmdletBinding()]
param(
  [string]$KeyFile = (Join-Path $PSScriptRoot '..\..\doran-village-admin-key.txt'),
  [string]$Source = (Join-Path $PSScriptRoot '..\src\doran-village.html'),
  [switch]$NewKey,
  [switch]$Json,
  [string]$Done = '',
  [string]$Reply = '',
  [int]$TimeoutSec = 6
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
public static class DvAsk {
  static BigInteger H(string s){ return BigInteger.Parse("00"+s, NumberStyles.HexNumber); }
  static readonly BigInteger P  = H("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F");
  static readonly BigInteger N  = H("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");
  static readonly BigInteger Gx = H("79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798");
  static readonly BigInteger Gy = H("483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8");
  static BigInteger Mod(BigInteger a){ a %= P; return a.Sign < 0 ? a + P : a; }
  static BigInteger Inv(BigInteger a){ return BigInteger.ModPow(Mod(a), P - 2, P); }
  static BigInteger[] Add(BigInteger[] a, BigInteger[] b){
    if (a == null) return b; if (b == null) return a;
    BigInteger l;
    if (a[0] == b[0]) { if (Mod(a[1] + b[1]).IsZero) return null; l = Mod(3 * a[0] * a[0] * Inv(2 * a[1])); }
    else l = Mod((b[1] - a[1]) * Inv(b[0] - a[0]));
    var x = Mod(l * l - a[0] - b[0]);
    return new[]{ x, Mod(l * (a[0] - x) - a[1]) };
  }
  static BigInteger[] Mul(BigInteger k, BigInteger[] pt){
    BigInteger[] r = null; var q = pt;
    while (k.Sign > 0) { if (!k.IsEven) r = Add(r, q); q = Add(q, q); k >>= 1; }
    return r;
  }
  static BigInteger Num(byte[] b){ return new BigInteger(b, true, true); }
  static byte[] To32(BigInteger v){ var b = v.ToByteArray(true, true); var o = new byte[32]; Buffer.BlockCopy(b, 0, o, 32 - b.Length, b.Length); return o; }
  public static byte[] FromHex(string h){ return Convert.FromHexString(h); }
  public static string ToHex(byte[] b){ return Convert.ToHexString(b).ToLowerInvariant(); }
  // 열쇠 글자 다듬기: 대문자로, 글자와 숫자만, 헷갈리는 글자(O→0, I·L→1)는 바꾼다. 게임의 askNorm과 같아야 한다
  public static string Norm(string s){
    var sb = new StringBuilder();
    foreach (var ch in (s ?? "").ToUpperInvariant()) {
      var c = ch; if (c == 'O') c = '0'; if (c == 'I' || c == 'L') c = '1';
      if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z')) sb.Append(c);
    }
    return sb.ToString();
  }
  public static byte[] SkFromPass(string pass){ return SHA256.HashData(Encoding.UTF8.GetBytes("doran-village-ask-admin|" + Norm(pass))); }
  public static string PubX(byte[] sk){
    var d = Num(sk); if (d.IsZero || d >= N) throw new Exception("bad key");
    return ToHex(To32(Mul(d, new[]{ Gx, Gy })[0]));
  }
  static byte[] SharedX(byte[] sk, string pubXHex){
    var x = Num(FromHex(pubXHex)); var y2 = Mod(x * x * x + 7); var y = BigInteger.ModPow(y2, (P + 1) / 4, P);
    if (Mod(y * y) != y2) throw new Exception("not on curve");
    return To32(Mul(Num(sk), new[]{ x, y })[0]);
  }
  // 게임이 잠근 글 풀기: 열쇠 = SHA-256(둘이 함께 아는 점의 x), 내용 = base64(iv 12 || 암호문 || 꼬리표 16), AES-256-GCM
  public static string Open(byte[] sk, string otherPubX, string b64){
    var key = SHA256.HashData(SharedX(sk, otherPubX));
    var raw = Convert.FromBase64String(b64); if (raw.Length < 29) throw new Exception("short");
    var iv = new byte[12]; var tag = new byte[16]; var ct = new byte[raw.Length - 28]; var pt = new byte[ct.Length];
    Buffer.BlockCopy(raw, 0, iv, 0, 12); Buffer.BlockCopy(raw, 12, ct, 0, ct.Length); Buffer.BlockCopy(raw, raw.Length - 16, tag, 0, 16);
    using (var g = new AesGcm(key, 16)) g.Decrypt(iv, ct, tag, pt);
    return Encoding.UTF8.GetString(pt);
  }
  // 답글 잠그기(Open의 반대): 게임이 풀 수 있게 base64(iv 12 || 암호문 || 꼬리표 16)
  public static string Seal(byte[] sk, string otherPubX, string json){
    var key = SHA256.HashData(SharedX(sk, otherPubX)); var iv = RandomNumberGenerator.GetBytes(12);
    var pt = Encoding.UTF8.GetBytes(json); var ct = new byte[pt.Length]; var tag = new byte[16];
    using (var g = new AesGcm(key, 16)) g.Encrypt(iv, pt, ct, tag);
    var raw = new byte[28 + ct.Length]; Buffer.BlockCopy(iv, 0, raw, 0, 12); Buffer.BlockCopy(ct, 0, raw, 12, ct.Length); Buffer.BlockCopy(tag, 0, raw, 12 + ct.Length, 16);
    return Convert.ToBase64String(raw);
  }
  static byte[] Tagged(string t, params byte[][] parts){
    var th = SHA256.HashData(Encoding.UTF8.GetBytes(t)); var len = 64; foreach (var p in parts) len += p.Length;
    var all = new byte[len]; Buffer.BlockCopy(th, 0, all, 0, 32); Buffer.BlockCopy(th, 0, all, 32, 32); var o = 64;
    foreach (var p in parts) { Buffer.BlockCopy(p, 0, all, o, p.Length); o += p.Length; }
    return SHA256.HashData(all);
  }
  // 서명(BIP-340 Schnorr): 중계 서버가 받아 주려면 글마다 운영자 열쇠의 서명이 있어야 한다
  public static string Sign(byte[] sk, byte[] msg32){
    var G = new[]{ Gx, Gy }; var d0 = Num(sk); var pt = Mul(d0, G); var d = pt[1].IsEven ? d0 : N - d0; var px = To32(pt[0]);
    var t = To32(d); var ha = Tagged("BIP0340/aux", RandomNumberGenerator.GetBytes(32)); for (int i = 0; i < 32; i++) t[i] ^= ha[i];
    var k0 = Num(Tagged("BIP0340/nonce", t, px, msg32)) % N; if (k0.IsZero) throw new Exception("nonce");
    var R = Mul(k0, G); var k = R[1].IsEven ? k0 : N - k0; var rx = To32(R[0]);
    var e = Num(Tagged("BIP0340/challenge", rx, px, msg32)) % N;
    var sig = new byte[64]; Buffer.BlockCopy(rx, 0, sig, 0, 32); Buffer.BlockCopy(To32((k + e * d) % N), 0, sig, 32, 32);
    return ToHex(sig);
  }
  public static string Sha256Hex(string s){ return ToHex(SHA256.HashData(Encoding.UTF8.GetBytes(s))); }
  public static string NewPass(){
    const string A = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; var b = RandomNumberGenerator.GetBytes(20); var sb = new StringBuilder();
    for (int i = 0; i < 20; i++) { if (i > 0 && i % 4 == 0) sb.Append('-'); sb.Append(A[b[i] & 31]); }
    return sb.ToString();
  }
}
'@

if ($NewKey) {
  if (Test-Path $KeyFile) { throw "열쇠 파일이 이미 있습니다: $KeyFile (새로 만들면 예전 글을 읽을 수 없게 됩니다. 정말 바꾸려면 그 파일을 먼저 옮기세요)" }
  $pass = [DvAsk]::NewPass()
  Set-Content -Path $KeyFile -Value $pass -Encoding utf8 -NoNewline
  "공개 열쇠(ASK_PUB): " + [DvAsk]::PubX([DvAsk]::SkFromPass($pass))
  "운영자 열쇠는 파일에 적었습니다: " + (Resolve-Path $KeyFile)
  return
}

if (-not (Test-Path $KeyFile)) { throw "운영자 열쇠 파일이 없습니다: $KeyFile" }
$src = Get-Content $Source -Raw -Encoding UTF8
$pub = [regex]::Match($src, "ASK_PUB='([0-9a-f]{64})'").Groups[1].Value
$kind = [regex]::Match($src, "ASK_KIND=(\d+)").Groups[1].Value
$relays = [regex]::Match($src, "ASK_RELAYS='([^']+)'").Groups[1].Value -split ' ' | Where-Object { $_ }
if (-not $pub -or -not $kind -or -not $relays) { throw "원본에서 ASK_PUB·ASK_KIND·ASK_RELAYS를 찾지 못했습니다: $Source" }
$sk = [DvAsk]::SkFromPass((Get-Content $KeyFile -Raw -Encoding UTF8))
if ([DvAsk]::PubX($sk) -ne $pub) { throw "열쇠 파일이 원본의 공개 열쇠(ASK_PUB)와 맞지 않습니다." }

# 중계 서버 하나에서 글 받기: 나에게 온 글(#p)과 내가 단 답글(authors)을 한 번에 묻고, 다 받았다는 말(EOSE)이 오거나 시간이 다 되면 끊는다
function Get-RelayEvents([string]$relay) {
  $ws = [System.Net.WebSockets.ClientWebSocket]::new()
  $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
  $got = [System.Collections.Generic.List[object]]::new()
  try {
    # 아래 두 호출의 빈 결과가 함수의 출력에 섞이지 않게 $null로 받는다
    $null = $ws.ConnectAsync([Uri]"wss://$relay", $cts.Token).GetAwaiter().GetResult()
    $req = '["REQ","a",{"kinds":[' + $kind + '],"#p":["' + $pub + '"],"limit":500},{"kinds":[' + $kind + '],"authors":["' + $pub + '"],"limit":500}]'
    $bytes = [Text.Encoding]::UTF8.GetBytes($req)
    $null = $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, $cts.Token).GetAwaiter().GetResult()
    $buf = [byte[]]::new(65536)
    while ($ws.State -eq 'Open') {
      $ms = [IO.MemoryStream]::new()
      do { $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).GetAwaiter().GetResult(); $ms.Write($buf, 0, $r.Count) } while (-not $r.EndOfMessage)
      if ($r.MessageType -eq 'Close') { break }
      $m = $null; try { $m = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($ms.ToArray())) -Depth 8 -NoEnumerate } catch { continue }
      if ($m -isnot [array] -or $m.Count -lt 2) { continue }
      if ($m[0] -eq 'EVENT' -and $m.Count -ge 3) { $got.Add($m[2]) } elseif ($m[0] -eq 'EOSE') { break }
    }
  } catch { Write-Verbose "${relay}: $($_.Exception.Message)" } finally { try { $ws.Dispose() } catch { } }
  Write-Verbose "${relay}: $($got.Count)"
  return , $got
}

$byId = @{}; $answered = 0
foreach ($relay in $relays) {
  $evs = Get-RelayEvents $relay
  if ($evs.Count) { $answered++ }
  foreach ($e in $evs) { if ($e.id -is [string] -and $e.id -match '^[0-9a-f]{64}$' -and -not $byId.ContainsKey($e.id)) { $byId[$e.id] = $e } }
}

$tagOf = { param($e, $n) foreach ($t in $e.tags) { if ($t.Count -ge 2 -and $t[0] -eq $n) { return [string]$t[1] } } return '' }

# -Done: 받은 글 하나를 처리함으로 표시한다(답글이 있으면 함께). 게임의 askEdit과 같은 글을 만들어 서명해서 중계 서버마다 올린다
if ($Done) {
  if ($Done -notmatch '^[0-9a-f]{6,64}$') { throw "-Done에는 글의 id(앞 여섯 자 이상)를 주세요." }
  $app = [regex]::Match($src, "ASK_APP='([^']+)'").Groups[1].Value
  if ($app -notmatch '^[A-Za-z0-9._:-]+$') { throw "원본에서 ASK_APP을 찾지 못했습니다." }
  $hit = @($byId.Values | Where-Object { $_.pubkey -ne $pub -and $_.pubkey -match '^[0-9a-f]{64}$' -and (& $tagOf $_ 'p') -eq $pub -and $_.id.StartsWith($Done) })
  if ($hit.Count -ne 1) { throw "그 id로 시작하는 받은 글이 $($hit.Count)건입니다. 하나만 가리키게 더 길게 적어 주세요." }
  $q = $hit[0]
  $body = [ordered]@{ re = $(if ($Reply.Length -gt 500) { $Reply.Substring(0, 500) } else { $Reply }); done = 1 } | ConvertTo-Json -Compress
  $content = [DvAsk]::Seal($sk, [string]$q.pubkey, $body)
  $tags = '[["d","' + $app + ':re:' + $q.id + '"],["p","' + $q.pubkey + '"],["e","' + $q.id + '"]]'
  $at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $id = [DvAsk]::Sha256Hex('[0,"' + $pub + '",' + $at + ',' + $kind + ',' + $tags + ',"' + $content + '"]')
  $sig = [DvAsk]::Sign($sk, [DvAsk]::FromHex($id))
  $msg = '["EVENT",{"id":"' + $id + '","pubkey":"' + $pub + '","created_at":' + $at + ',"kind":' + $kind + ',"tags":' + $tags + ',"content":"' + $content + '","sig":"' + $sig + '"}]'
  $okN = 0
  foreach ($relay in $relays) {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new(); $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
      $null = $ws.ConnectAsync([Uri]"wss://$relay", $cts.Token).GetAwaiter().GetResult()
      $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
      $null = $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, $cts.Token).GetAwaiter().GetResult()
      $buf = [byte[]]::new(65536)
      while ($ws.State -eq 'Open') {
        $ms = [IO.MemoryStream]::new()
        do { $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).GetAwaiter().GetResult(); $ms.Write($buf, 0, $r.Count) } while (-not $r.EndOfMessage)
        if ($r.MessageType -eq 'Close') { break }
        $m = $null; try { $m = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($ms.ToArray())) -Depth 4 -NoEnumerate } catch { continue }
        if ($m -is [array] -and $m.Count -ge 3 -and $m[0] -eq 'OK' -and $m[1] -eq $id) { if ($m[2] -eq $true) { $okN++ } else { Write-Verbose "${relay}: 거절 $($m[3])" }; break }
      }
    } catch { Write-Verbose "${relay}: $($_.Exception.Message)" } finally { try { $ws.Dispose() } catch { } }
  }
  "글 $($q.id.Substring(0,8))을(를) 처리함으로 표시했습니다: 중계 서버 $(@($relays).Count)곳 중 ${okN}곳이 받음" + $(if ($Reply) { ' (답글 포함)' } else { '' })
  if (-not $okN) { throw "어느 서버도 받지 않았습니다. -Verbose로 까닭을 보세요." }
  return
}
$cut = { param($s, $n) $s = [string]$s; if ($s.Length -gt $n) { $s.Substring(0, $n) } else { $s } }
# 내가 단 답글: 어느 글(e)에 달았는지별로 가장 새것만
$replies = @{}
foreach ($e in $byId.Values) {
  if ($e.pubkey -ne $pub) { continue }
  $to = & $tagOf $e 'e'; $who = & $tagOf $e 'p'
  if ($to -notmatch '^[0-9a-f]{64}$' -or $who -notmatch '^[0-9a-f]{64}$') { continue }
  if ($replies.ContainsKey($to) -and $replies[$to].at -ge $e.created_at) { continue }
  try { $d = [DvAsk]::Open($sk, $who, [string]$e.content) | ConvertFrom-Json; $replies[$to] = @{ at = [long]$e.created_at; re = (& $cut $d.re 500); done = [bool]$d.done } } catch { }
}
$kinds = '문의', '요청', '버그'
$items = foreach ($e in $byId.Values) {
  if ($e.pubkey -eq $pub -or $e.pubkey -notmatch '^[0-9a-f]{64}$' -or (& $tagOf $e 'p') -ne $pub) { Write-Verbose "skip $($e.id.Substring(0,8)): from=$($e.pubkey.Substring(0,6)) p=$(& $tagOf $e 'p')"; continue }
  try { $d = [DvAsk]::Open($sk, [string]$e.pubkey, [string]$e.content) | ConvertFrom-Json } catch { Write-Verbose "cannot open $($e.id.Substring(0,8)): $($_.Exception.Message)"; continue }
  if ($d.x -isnot [string] -or -not $d.x) { Write-Verbose "no text $($e.id.Substring(0,8))"; continue }
  $r = $replies[$e.id]
  [pscustomobject]@{
    when   = [DateTimeOffset]::FromUnixTimeSeconds([long]$e.created_at).ToLocalTime().ToString('MM-dd HH:mm')
    kind   = if ($kinds -contains $d.k) { $d.k } else { $kinds[0] }
    text   = & $cut $d.x 500
    ver    = [int]$d.v; level = [int]$d.lv; day = [int]$d.d
    sender = $e.pubkey.Substring(0, 6)
    reply  = if ($r) { if ($r.re) { $r.re } elseif ($r.done) { '(답글 없이 처리함)' } else { '' } } else { '' }
    at     = [long]$e.created_at
    id     = $e.id.Substring(0, 8)
  }
}
$items = @($items | Sort-Object at -Descending)
if ($Json) { [pscustomobject]@{ relaysAnswered = $answered; relaysAsked = @($relays).Count; count = $items.Count; open = @($items | Where-Object { -not $_.reply }).Count; items = $items } | ConvertTo-Json -Depth 5; return }
"중계 서버 $(@($relays).Count)곳 중 ${answered}곳이 글을 돌려줌 · 받은 글 $($items.Count)건 · 답글 안 단 것 $(@($items | Where-Object { -not $_.reply }).Count)건"
if ($items.Count) { $items | Format-Table when, kind, sender, text, ver, level, reply -Wrap }
