#!/bin/bash
cd ../devstats-k8s-lf/util/
./recent_cronjobs_logs.sh ../../devstats-docker-images/devstats-helm/all_test_projects.txt logs.txt
