param([string]$EvidencePath)

$ErrorActionPreference = 'Stop'

function Get-ClusterJson {
    param([string[]]$Arguments)
    $result = kubectl --context aks-hack-lab @Arguments -o json
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($Arguments -join ' ')" }
    return ($result -join "`n" | ConvertFrom-Json)
}

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

function Invoke-PodNode {
    param([string]$PodName, [string]$Script)
    $output = $Script | kubectl --context aks-hack-lab exec -i -n fabtech $PodName -- node
    if ($LASTEXITCODE -ne 0) { throw "Pod validation failed: $PodName" }
    return ($output -join "`n" | ConvertFrom-Json)
}

$databasePvc = Get-ClusterJson @('get', 'pvc', 'data-c09-postgresql-0', '-n', 'fabtech')
$databasePv = Get-ClusterJson @('get', 'pv', $databasePvc.spec.volumeName)
Assert-Check ($databasePvc.status.phase -eq 'Bound' -and $databasePv.spec.csi.driver -eq 'disk.csi.azure.com') 'Explicit PostgreSQL uses a bound Azure Disk CSI volume'
Assert-Check ($databasePvc.spec.storageClassName -eq 'c09-postgres-disk' -and $databasePvc.spec.accessModes -contains 'ReadWriteOnce') 'Database uses the custom StorageClass and RWO'
Assert-Check ($databasePv.spec.persistentVolumeReclaimPolicy -eq 'Retain') 'Database disk is protected with Retain'
$historical = Get-Content (Join-Path $PSScriptRoot 'challenge09-database-evidence.json') -Raw | ConvertFrom-Json
Assert-Check ($historical.before.podUid -ne $historical.after.podUid -and $historical.before.pvcUid -eq $historical.after.pvcUid -and $historical.before.pv -eq $historical.after.pv) 'Recorded pod recreation changed the pod UID, not its persistent volume'
$currentJson = node (Join-Path $PSScriptRoot 'c09-database.cjs') verify
Assert-Check ($LASTEXITCODE -eq 0) 'Persistent marker and migrated data remain readable'
$current = $currentJson -join "`n" | ConvertFrom-Json
Assert-Check ($current.pv -eq $historical.after.pv -and $current.data.sessionsHash -eq $historical.after.data.sessionsHash -and $current.data.speakersHash -eq $historical.after.data.speakersHash) 'Current database matches the verified post-recreation data'

$sharedPvc = Get-ClusterJson @('get', 'pvc', 'c09-shared-content-mi', '-n', 'fabtech')
$sharedPv = Get-ClusterJson @('get', 'pv', $sharedPvc.spec.volumeName)
Assert-Check ($sharedPvc.status.phase -eq 'Bound' -and $sharedPvc.spec.accessModes -contains 'ReadWriteMany' -and $sharedPv.spec.csi.driver -eq 'file.csi.azure.com') 'Shared PVC is Azure Files RWX'
Assert-Check ($sharedPv.spec.csi.volumeAttributes.mountWithManagedIdentity -eq 'true' -and -not $sharedPv.spec.csi.nodeStageSecretRef) 'Azure Files mounts using Managed Identity without a storage-key Secret'

$pods = Get-ClusterJson @('get', 'pods', '-n', 'fabtech')
$ready = @($pods.items | Where-Object { -not $_.metadata.deletionTimestamp -and $_.status.phase -eq 'Running' -and @($_.status.containerStatuses | Where-Object { -not $_.ready }).Count -eq 0 })
$web = @($ready | Where-Object { $_.metadata.labels.app -eq 'fabtech-web' })[0]
$api = @($ready | Where-Object { $_.metadata.labels.app -eq 'fabtech-api' -and $_.spec.nodeName -ne $web.spec.nodeName })[0]
Assert-Check ([bool]$web -and [bool]$api) 'Ready API and Web pods exist on different nodes'
foreach ($pod in @($web, $api)) {
    Assert-Check (@($pod.spec.volumes | Where-Object { $_.persistentVolumeClaim.claimName -eq 'c09-shared-content-mi' }).Count -eq 1) "$($pod.metadata.name) mounts the same RWX claim"
}

$proofId = [guid]::NewGuid().ToString('N')
$directory = "/mnt/shared/challenge09-$proofId"
$write = @'
const fs=require('node:fs');
const assert=require('node:assert/strict');
assert.equal(process.getuid(),100);
const folder='__DIRECTORY__';
fs.mkdirSync(folder);
fs.writeFileSync(folder+'/proof.json', JSON.stringify({id:'__ID__',writtenBy:'web',pod:process.env.HOSTNAME}), {flag:'wx'});
console.log(JSON.stringify({written:true,uid:process.getuid(),pod:process.env.HOSTNAME}));
'@
$webWrite = Invoke-PodNode $web.metadata.name ($write.Replace('__DIRECTORY__', $directory).Replace('__ID__', $proofId))

$modify = @'
const fs=require('node:fs');
const assert=require('node:assert/strict');
const folder='__DIRECTORY__';
const proof=JSON.parse(fs.readFileSync(folder+'/proof.json','utf8'));
assert.equal(proof.id,'__ID__');
assert.equal(proof.writtenBy,'web');
proof.updatedBy='api';
proof.apiPod=process.env.HOSTNAME;
fs.writeFileSync(folder+'/proof.json',JSON.stringify(proof));
console.log(JSON.stringify({readAndUpdated:true,uid:process.getuid(),pod:process.env.HOSTNAME}));
'@
$apiWrite = Invoke-PodNode $api.metadata.name ($modify.Replace('__DIRECTORY__', $directory).Replace('__ID__', $proofId))

$read = @'
const fs=require('node:fs');
const assert=require('node:assert/strict');
const proof=JSON.parse(fs.readFileSync('__DIRECTORY__/proof.json','utf8'));
assert.equal(proof.id,'__ID__');
assert.equal(proof.updatedBy,'api');
console.log(JSON.stringify({crossNodeReadWrite:true,proof}));
'@
$sharedProof = Invoke-PodNode $web.metadata.name ($read.Replace('__DIRECTORY__', $directory).Replace('__ID__', $proofId))
Assert-Check ($sharedProof.crossNodeReadWrite) 'Web writes, API reads and updates, Web reads back across nodes'

$databaseProbe = @'
const fs=require('node:fs');
const assert=require('node:assert/strict');
const {Client}=require('pg');
(async()=>{
  assert.equal(process.env.DATABASE_URL,undefined);
  const connection=fs.readFileSync('/mnt/secrets/db-connection-string','utf8').trim();
  assert.equal(new URL(connection).hostname,'c09-postgresql.fabtech.svc.cluster.local');
  const client=new Client({connectionString:connection,connectionTimeoutMillis:5000});
  await client.connect();
  try{
    const result=await client.query("SELECT inet_server_addr()::text AS server, (SELECT count(*)::int FROM c09_storage_proof WHERE proof_id='challenge09-persistent-disk') AS marker");
    assert.equal(result.rows[0].marker,1);
    console.log(JSON.stringify({newDatabase:true,host:new URL(connection).hostname,server:result.rows[0].server,marker:result.rows[0].marker}));
  }finally{await client.end();}
})().catch(()=>{console.error('API database test failed; credentials not printed');process.exitCode=1;});
'@
$connectionEvidence = Invoke-PodNode $api.metadata.name $databaseProbe
Assert-Check ($connectionEvidence.newDatabase) 'API connects to the migrated database using the CSI-mounted Key Vault value'
$stats = Invoke-RestMethod 'http://crf5dvezf8ambtg5.fz88.alb.azure.com/api/stats' -TimeoutSec 30
$sessions = Invoke-RestMethod 'http://crf5dvezf8ambtg5.fz88.alb.azure.com/api/sessions' -TimeoutSec 30
Assert-Check ($stats.dataSource -eq 'postgresql' -and @($sessions).Count -eq 4) 'Public AGC-Web-API-PostgreSQL flow is healthy'

$evidence = [ordered]@{
    verifiedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    database = $current
    diskResourceId = $databasePv.spec.csi.volumeHandle
    sharedPv = $sharedPv.metadata.name
    sharedAttributes = $sharedPv.spec.csi.volumeAttributes
    sharedDirectory = $directory
    web = @{pod=$web.metadata.name;node=$web.spec.nodeName;write=$webWrite}
    api = @{pod=$api.metadata.name;node=$api.spec.nodeName;write=$apiWrite;connection=$connectionEvidence}
    proof = $sharedProof.proof
    publicFlow = 'PASS'
}
if ($EvidencePath) { $evidence | ConvertTo-Json -Depth 12 | Set-Content $EvidencePath -Encoding utf8 }
Write-Host "PASS: Challenge 09 storage validation. Shared proof retained at $directory/proof.json"