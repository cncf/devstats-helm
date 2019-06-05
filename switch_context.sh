#!/bin/bash
if [ -z "$1" ]
then
  echo "$0: you need to provide context name as an argument"
  exit 1
fi
kubectl config use-context $1
