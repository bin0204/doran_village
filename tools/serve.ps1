param([int]$Port=8765,[string]$Root)
$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port);$l.Start()
Write-Host "serving $Root on http://localhost:$Port"
while($true){
  $c=$l.AcceptTcpClient()
  try{
    $s=$c.GetStream();$s.ReadTimeout=2000
    $buf=New-Object byte[] 8192;$n=$s.Read($buf,0,$buf.Length)
    $req=[Text.Encoding]::ASCII.GetString($buf,0,$n)
    $path=($req -split "`r`n")[0].Split(' ')[1].Split('?')[0]
    if($path -eq '/'){$path='/test.html'}
    $file=Join-Path $Root ([Uri]::UnescapeDataString($path.TrimStart('/')))
    if((Test-Path $file -PathType Leaf) -and ((Resolve-Path $file).Path.StartsWith($Root))){
      $body=[IO.File]::ReadAllBytes($file);$ct='text/html; charset=utf-8';$st='200 OK'
    }else{$body=[Text.Encoding]::UTF8.GetBytes('not found');$ct='text/plain';$st='404 Not Found'}
    $h=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $st`r`nContent-Type: $ct`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
    $s.Write($h,0,$h.Length);$s.Write($body,0,$body.Length);$s.Flush()
  }catch{}finally{$c.Close()}
}
