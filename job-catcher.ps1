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

# --- 2. APPLY THE POD ---
$podYaml | kubectl apply -f -

# --- 3. GET THE JOBS AND SAVE THEM ---

$caughtJobName = (kubectl get jobs -n $namespace -o=jsonpath="{.items[*].metadata.name}") -split " " | Where-Object { $_ }
    
$podName = kubectl get pods -n $namespace --selector=job-name=$caughtJobName -o=jsonpath="{.items[0].metadata.name}"
    
sleep(1000)

kubectl describe pod $podName -n trivy-system > describePod.yaml

kubectl logs $podName -n $namespace > jobLogs.txt


kubectl get job $caughtJobName -n $namespace -o yaml > jobFile.yaml

Write-Host "Script finished"



