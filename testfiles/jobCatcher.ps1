$namespace = "trivy-system"
$outputDirectory = ".\trivy-job-diagnostics" 
$pollIntervalSeconds = 2    
$idleTimeoutSeconds = 60      
$podWaitTimeoutSeconds = 30   


# Create a list to keep track of jobs we've already processed
$processedJobs = New-Object System.Collections.Generic.HashSet[string]


if (-not (Test-Path -Path $outputDirectory)) {
    Write-Host "Creating output directory: $outputDirectory"
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

Write-Host "Starting to watch for new jobs in namespace '$namespace'..."
Write-Host "Script will time out after $idleTimeoutSeconds seconds of inactivity."

$idleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

while ($true) {
    $currentJobs = kubectl get jobs -n $namespace -o name 2>$null

    $newJobFound = $false

    foreach ($job in $currentJobs) {
        # Extract just the job name from "job.batch/..."
        $jobName = $job.Split('/')[1]

        # Check if we have already processed this job
        if (-not $processedJobs.Contains($jobName)) {
            
            $newJobFound = $true
            $idleStopwatch.Restart() 
            
            Write-Host "New job detected: $jobName. Capturing diagnostics..."

            # Add to our list so we don't process it again
            $processedJobs.Add($jobName) | Out-Null

            # Create a specific folder for this job's artifacts
            $jobSpecificDir = Join-Path -Path $outputDirectory -ChildPath $jobName
            if (-not (Test-Path -Path $jobSpecificDir)) {
                New-Item -ItemType Directory -Path $jobSpecificDir | Out-Null
            }

            # 1. Get static job information (these don't require the pod to be running)
            Write-Host "   - Describing job..."
            kubectl describe job $jobName -n $namespace > (Join-Path $jobSpecificDir "describe-job.yaml")

            Write-Host "   - Getting events..."
            kubectl get events -n $namespace --field-selector involvedObject.name=$jobName,involvedObject.kind=Job > (Join-Path $jobSpecificDir "events.yaml")

            Write-Host "   - Getting job manifest..."
            kubectl get job $jobName -n $namespace -o yaml > (Join-Path $jobSpecificDir "job.yaml")
            
            # 2. Find the pod for this job and wait for it to run
            Write-Host "   - Searching for pod belonging to job '$jobName'..."
            $podName = $null
            $podWaitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            while ($podWaitStopwatch.Elapsed.TotalSeconds -lt $podWaitTimeoutSeconds) {
                $foundPod = kubectl get pods -n $namespace -l job-name=$jobName -o=jsonpath='{.items[0].metadata.name}' 2>$null
                if ($foundPod) {
                    $podName = $foundPod
                    break 
                }
                Start-Sleep -Milliseconds 500
            }

            if ($podName) {
                Write-Host "     - Found pod: $podName. Getting init container details..."

                # Get the name of the first init container from the pod spec
                $initContainerName = kubectl get pod $podName -n $namespace -o=jsonpath='{.spec.initContainers[0].name}' 2>$null

                if (-not $initContainerName) {
                    Write-Warning "     - Could not find an init container in pod $podName."
                       

                } else {
                    Write-Host "     - Found init container: $initContainerName. Discovering and copying files..."

                    Write-Host "     - Describing pod to see init container status..."
                    kubectl describe pod $podName -n $namespace > (Join-Path $jobSpecificDir "describe-pod_init.yaml")

                    Write-Host "     - Getting pod manifest to see init container spec..."
                    kubectl get pod $podName -n $namespace -o yaml > (Join-Path $jobSpecificDir "pod-manifest_init.yaml")

                    Write-Host "     - Getting init container details..."
                    $initContainerName = kubectl get pod $podName -n $namespace -o=jsonpath='{.spec.initContainers[0].name}' 2>$null

                    
                    $targetDirectories = @(
                        "/tmp/trivy-vex",
                        "/tmp/trivy-1"
                    )

                    foreach ($directory in $targetDirectories) {
                        try {
                            # Create a local sub-directory to mirror the pod's directory structure
                            $localSubDirName = $directory.Split('/')[-1]
                            $localSubDirPath = Join-Path $jobSpecificDir $localSubDirName
                            New-Item -ItemType Directory -Path $localSubDirPath -ErrorAction SilentlyContinue | Out-Null

                            Write-Host "       - Listing files in pod directory '$directory'..."
                            # Get the list of filenames from the init container
                            $filesInPod = kubectl exec $podName -n $namespace -c $initContainerName -- ls $directory
                            
                            if ($filesInPod) {
                                # Loop through each file found and copy it with a new name
                                foreach ($file in $filesInPod) {
                                    if ([string]::IsNullOrWhiteSpace($file)) { continue }
                                    
                                    $trimmedFile = $file.Trim()
                                    $sourcePathInPod = "$directory/$trimmedFile"

                                    # --- CONSTRUCT THE NEW FILENAME ---
                                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($trimmedFile)
                                    $extension = [System.IO.Path]::GetExtension($trimmedFile)
                                    $newLocalFileName = "${baseName}_init${extension}"
                                    $destinationPathLocal = Join-Path $localSubDirPath $newLocalFileName
                                    
                                    Write-Host "         - Copying '$sourcePathInPod' to '$destinationPathLocal'..."
                                    # Use kubectl cp, specifying the init container name with -c
                                    kubectl cp "$Namespace/$podName`:$sourcePathInPod" $destinationPathLocal -c $initContainerName
                                }
                            } else {
                                Write-Host "       - Directory is empty."
                            }
                        } catch {
                            Write-Warning "       - Could not list or copy files from '$directory'. It might not exist or the pod terminated."
                        }
                    }
                }
            } else {
                Write-Warning "   - Timed out waiting for a pod for job '$jobName'. Skipping file content retrieval."
            }

            # 3. Get the logs (this should be done last to get the complete log)
            Write-Host "   - Getting logs..."
            kubectl logs job/$jobName -n $namespace --all-containers=true --tail=-1 > (Join-Path $jobSpecificDir "logs.log")

            Write-Host "   - Done capturing diagnostics for $jobName."
        }
    }

    if ((!$newJobFound) -and ($idleStopwatch.Elapsed.TotalSeconds -ge $idleTimeoutSeconds)) {
        Write-Host "Timeout of $idleTimeoutSeconds seconds reached. No new jobs detected. Exiting."
        break
    }

    Start-Sleep -Seconds $pollIntervalSeconds
}