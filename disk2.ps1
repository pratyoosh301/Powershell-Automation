$threshold=10
$free=[Math]::round(((Get-PsDrive -Name "C").Free/1GB),2)
$total=(Get-PsDrive -Name "C").Used/1GB+$free
$freepercent=($free/$total)*100
if($freepercent -lt $threshold){
Write-Output "below Threshhold its $freepercent"
}
else{
Write-Output "its safe its $free % free and total is $total"}
