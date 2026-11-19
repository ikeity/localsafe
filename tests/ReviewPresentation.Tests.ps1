# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.UninstallUi.psm1') -Force
$render=& (Get-Module LocalSafe.UninstallUi) {${function:Get-LSReviewPresentation}}
$v=[pscustomobject]@{Code='Remaining';Title='Original detailed status';Eligible=31;Remaining=37;Direct=31;Failures=0;Incomplete=0;Quarantined=0}
$s=[pscustomobject]@{Verdict=$v}
$view=& $render $s
if($view.Title -ne '发现遗留' -or $view.Summary -ne '31 项可清理 · 6 项保留'){throw 'Keep the default summary short and preserve accurate retained counts.'}
$v.Eligible=0;$v.Direct=0
if((& $render $s).Title -ne '仍有待核对项'){throw 'Candidate-only findings must not claim confirmed residues.'}
$v.Failures=2;$v.Incomplete=1
$view=& $render $s
if(!$view.Summary.Contains('2 项失败') -or !$view.Summary.Contains('1 处未完成检查')){throw 'Do not hide operation failures or coverage gaps during copy reduction.'}
$v.Code='ClearWithinScope';$v.Remaining=0;$v.Failures=0;$v.Incomplete=0
if((& $render $s).Title -ne '检查范围内未发现遗留'){throw 'Keep the scope boundary in the clear verdict.'}
'PASS: concise counts, retained candidates, visible failures/coverage gaps and bounded cleanup claims.'
