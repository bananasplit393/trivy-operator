# Clear the screen for a clean output
Clear-Host

$namespace = "trivy-system"

# --- 1. DEFINE THE POD THAT TRIGGERS THE JOB ---
$podYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: nginx-test-pod
  namespace: $namespace
  labels:
    app: nginx-test
spec:
  containers:
  - name: nginx
    image: nginx:1.20.0
"@

# --- 2. GET A BASELINE OF EXISTING JOBS ---
# Get the raw output of job names
$jobsOutput = kubectl get jobs -n $namespace -o=jsonpath='{.items[*].metadata.name}'

# --- 3. APPLY THE POD ---
$podYaml | kubectl apply -f -

$caughtJobName = (kubectl get jobs -n $namespace -o=jsonpath="{.items[*].metadata.name}") -split " " | Where-Object { $_ }
    
# --- 4. WAIT FOR THE JOB TO COMPLETE ---
$podName = kubectl get pods -n $namespace --selector=job-name=$caughtJobName -o=jsonpath="{.items[0].metadata.name}"
    
kubectl logs $podName -n $namespace > jobLogs.txt
Write-Host "   -> Logs saved to jobLogs.txt"

kubectl get job $caughtJobName -n $namespace -o yaml > jobFileWithconfigFileAndTrivyOperatorFlag.yaml
Write-Host "   -> YAML saved to jobFileWithconfigFileAndTrivyOperatorFlag.yaml"


Write-Host "`n🎉 Script finished."