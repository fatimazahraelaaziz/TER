#!/bin/bash

# Check if the user has provided an argument
if [ $# -eq 0 ]; then
  echo "Please provide the number of log minutes to be retrieved. Example: scripts/launchExperience.sh 20"
  exit 1
fi

minutes=$1

printf "\n\033[1;36m## Deleting the previous deployment\033[0m\n"
kubectl delete -f kubernetes/deployment.yml

sleep 30

printf "\n\033[1;36m## Starting the experience\033[0m\n"
ansible-playbook newAnsible/deploy-app.yaml

printf "\n\033[1;36m## Waiting 5 minutes for the end of the experience\033[0m\n"
sleep 300

while true; do
    desired_replicas=$(kubectl get deployment latency -o=jsonpath='{.spec.replicas}')
    if [ "$desired_replicas" -ge 2 ]; then
        echo "Experience not yet finished, retrying in 1 min"
        sleep 60 # Adjust the interval as needed
    else
        echo "Experience finished"
        break
    fi
done

# Start port forwarding
kubectl port-forward svc/kibana-kb-http 15601:5601 -n elastic &
forward_pid=$!

# Function to stop port forwarding
stop_port_forwarding() {
    kill $forward_pid
}

sleep 1

# Start and get report
ELASTIC_PASSWORD=$(kubectl get secret elastic-cluster-es-elastic-user -o go-template='{{.data.elastic | base64decode}}' -n elastic)
echo "Get password : $ELASTIC_PASSWORD"

# Create data view
echo "Create or replace data view : Cluster logs"
curl --insecure \
-X POST 'https://localhost:15601/api/data_views/data_view' \
--header 'kbn-xsrf: creating' \
--header 'Content-Type: application/json' \
--header "Authorization: Basic $(echo -n "elastic:$ELASTIC_PASSWORD" | base64)" \
--data-raw '{
  "override": true,
  "data_view": {
     "title": "f*",
     "name": "Cluster logs",
     "id": "latency-id",
     "timeFieldName": "@timestamp"
  }
}'

# Execute POST request for start the report on the last 10 minutes
echo "Request reporting"
fullUrl="https://localhost:15601/api/reporting/generate/csv_searchsource?jobParams=%28browserTimezone%3AEurope%2FParis%2Ccolumns%3A%21%28%27%40timestamp%27%2Cmessage%2Ckubernetes.pod.name%29%2CobjectType%3Asearch%2CsearchSource%3A%28fields%3A%21%28%28field%3A%27%40timestamp%27%2Cinclude_unmapped%3Atrue%29%2C%28field%3Amessage%2Cinclude_unmapped%3Atrue%29%2C%28field%3Akubernetes.pod.name%2Cinclude_unmapped%3Atrue%29%29%2Cfilter%3A%21%28%28meta%3A%28field%3A%27%40timestamp%27%2Cindex%3A%27latency-id%27%2Cparams%3A%28%29%29%2Cquery%3A%28range%3A%28%27%40timestamp%27%3A%28format%3Astrict_date_optional_time%2Cgte%3Anow-" + $minutes + "m%2Clte%3Anow%29%29%29%29%29%2Cindex%3A%27latency-id%27%2Cparent%3A%28filter%3A%21%28%28%27%24state%27%3A%28store%3AappState%29%2Cmeta%3A%28alias%3A%21n%2Cdisabled%3A%21f%2Cindex%3A%27latency-id%27%2Ckey%3Akubernetes.deployment.name%2Cnegate%3A%21f%2Cparams%3A%28query%3Alatency%29%2Ctype%3Aphrase%29%2Cquery%3A%28match_phrase%3A%28kubernetes.deployment.name%3Alatency%29%29%29%2C%28%27%24state%27%3A%28store%3AappState%29%2Cmeta%3A%28alias%3
response_post=$(
 curl --insecure \
 -H "Authorization: Basic $(echo -n "elastic:$ELASTIC_PASSWORD" | base64)" \
 -H "kbn-xsrf: reporting" \
 -X POST \
 $fullUrl
)

echo "Post response : $reponse_post"

# Extract the path from the response
url=$(echo "$response_post" | jq -r '.path')
echo "Path to get report : $url"

logs_file="python/input/result.csv"

# Loop until the response is different from "wait"
while true; do
    # Execute GET request to get the report
    curl --insecure -H "Authorization: Basic $(echo -n "elastic:$ELASTIC_PASSWORD" | base64)" "https://localhost:15601$url" -o "$logs_file" -s
    
    # Verify if the response is different from "processing"
    if grep -q -v -e "pending" -e "processing" "$logs_file"; then
        echo "Logs saved in $logs_file"
        break
    else
	    echo "Still processing, retrying in 1 min"
    fi
    
    # Sleep for 1 minute
    sleep 60
done

# Stop port forwarding
stop_port_forwarding

# Execute the python script
printf "\n\033[1;36m## Executing main.py\033[0m\n"
python3 python/main.py
printf "\n\033[1;36m## Executing cdf.py\033[0m\n"
python3 python/cdf.py
# python3 python/displayPlotLag.py

printf "\n\033[1;36m## Results are available in the python/output folder\033[0m\n"
