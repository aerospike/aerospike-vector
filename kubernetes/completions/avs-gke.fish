# avs-gke.fish
complete -c full-create-and-install-gke.sh -l chart-location -s l -d "Local directory for AVS Helm chart"
complete -c full-create-and-install-gke.sh -l cluster-name -s c -d "Override default cluster name"
complete -c full-create-and-install-gke.sh -l image-tag -s g -d "Docker image tag for AVS"
complete -c full-create-and-install-gke.sh -l jfrog-user -s u -d "JFrog username"
complete -c full-create-and-install-gke.sh -l jfrog-token -s t -d "JFrog token"
complete -c full-create-and-install-gke.sh -l chart-version -s v -d "Helm chart version"
complete -c full-create-and-install-gke.sh -l machine-type -s m -d "Default machine type" -a "n2d-standard-4 n2-standard-8 e2-standard-4"
complete -c full-create-and-install-gke.sh -l standalone-machine-type -s S -d "Standalone node machine type" -a "n2d-standard-4 n2-standard-8 e2-standard-4"
complete -c full-create-and-install-gke.sh -l query-machine-type -s Q -d "Query node machine type" -a "n2d-standard-4 n2-standard-8 e2-standard-4"
complete -c full-create-and-install-gke.sh -l index-machine-type -s X -d "Index node machine type" -a "n2d-standard-4 n2-standard-8 e2-standard-4"
complete -c full-create-and-install-gke.sh -l num-avs-nodes -s a -d "Number of AVS nodes"
complete -c full-create-and-install-gke.sh -l num-query-nodes -s q -d "Number of query nodes"
complete -c full-create-and-install-gke.sh -l num-index-nodes -s i -d "Number of index nodes"
complete -c full-create-and-install-gke.sh -l num-standalone-nodes -s d -d "Number of standalone nodes"
complete -c full-create-and-install-gke.sh -l num-aerospike-nodes -s s -d "Number of Aerospike nodes"
complete -c full-create-and-install-gke.sh -l run-insecure -s I -d "Run without auth/TLS"
complete -c full-create-and-install-gke.sh -l cleanup -s C -d "Clean up cluster"
complete -c full-create-and-install-gke.sh -l help -s h -d "Show help"
complete -c full-create-and-install-gke.sh -l log-level -s L -d "Set AVS logging level" -a "debug info warn error" 