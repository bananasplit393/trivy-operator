# Clear the screen for a clean output
Clear-Host

# --- CONFIGURATION ---
$namespace = "trivy-system"
$timeoutSeconds = 30 # Set a timeout to avoid waiting forever

# Define the pod that will trigger the scan job
$podYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: nginx-test-pod
  namespace: $namespace
spec:
  containers:
  - name: nginx
    image: nginx:1.20.0
"@

# --- 1. PRE-SCRIPT CLEANUP ---
# Ensure a clean slate by removing resources from previous runs.
# This uses a label selector to safely delete only old trivy scan jobs.
Write-Host "Performing pre-script cleanup..."
kubectl delete pod nginx-test-pod -n $namespace --ignore-not-found=true
kubectl delete jobs -n $namespace -l 'trivy-operator.resource.kind=Pod' --ignore-not-found=true
Write-Host "Cleanup complete."

# --- 2. APPLY THE POD TO TRIGGER THE SCAN ---
Write-Host "Applying pod 'nginx-test-pod' to trigger a new scan job..."
$podYaml | kubectl apply -f -

# --- 3. WAIT FOR THE NEW SCAN JOB TO BE CREATED ---
Write-Host "Waiting for the new scan job to appear (timeout: $timeoutSeconds seconds)..."
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$caughtJobName = $null

while ($stopwatch.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    # Get all job names and filter for the one created by trivy-operator for vulnerability scans
    $scanJob = (kubectl get jobs -n $namespace -o=jsonpath='{.items[*].metadata.name}') -split ' ' | Where-Object { $_ -like "scan-vulnerabilityreport-*" }
    
    if ($scanJob) {
        $caughtJobName = $scanJob
        Write-Host "`n Caught new job: $caughtJobName"
        break
    }
    
    Start-Sleep -Seconds 2
    Write-Host -NoNewline "." 
}
$stopwatch.Stop()

# Check if we timed out
if (-not $caughtJobName) {
    Write-Host "`n Error: Timed out waiting for a new scan job. Cleaning up."
    kubectl delete pod nginx-test-pod -n $namespace --ignore-not-found=true
    exit 1
}

# --- 4. GET THE POD ASSOCIATED WITH THE JOB ---
Write-Host "Waiting for the pod associated with job '$caughtJobName'..."
$stopwatch.Restart()
$podName = $null

while ($stopwatch.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    $podName = kubectl get pods -n $namespace --selector=job-name=$caughtJobName -o=jsonpath="{.items[0].metadata.name}"
    if ($podName) {
        Write-Host "`n Found pod: $podName"
        break
    }
    Start-Sleep -Seconds 2
    Write-Host -NoNewline "." 
}
$stopwatch.Stop()

# Check if we timed out
if (-not $podName) {
    Write-Host "`n Error: Timed out waiting for the job's pod. Cleaning up."
    kubectl delete pod nginx-test-pod -n $namespace --ignore-not-found=true
    kubectl delete job $caughtJobName -n $namespace --ignore-not-found=true
    exit 1
}

# --- 5. COLLECT ARTIFACTS ---
Write-Host "Collecting artifacts for pod '$podName'..."

# Wait until the pod is initialized before trying to get logs/description
kubectl wait pod $podName -n $namespace --for=condition=Initialized --timeout=120s

kubectl describe pod $podName -n $namespace > describePod.yaml
Write-Host "  -> Pod description saved to describePod.yaml"

kubectl get job $caughtJobName -n $namespace -o yaml > jobFile.yaml
Write-Host "  -> Job YAML saved to jobFile.yaml"

# It can take a moment for logs to be available after the pod initializes
# Sometimes logs aren't available 
Start-Sleep -Seconds 5 
kubectl logs $podName -n $namespace --tail=-1 > jobLogs.txt
Write-Host "  -> Pod logs saved to jobLogs.txt"

# --- 6. CLEANUP ---
Write-Host "Performing post-script cleanup..."
kubectl delete pod nginx-test-pod -n $namespace --ignore-not-found=true
kubectl delete job $caughtJobName -n $namespace --ignore-not-found=true
Write-Host "  -> Deleted pod 'nginx-test-pod' and job '$caughtJobName'."

Write-Host "`n Script finished."