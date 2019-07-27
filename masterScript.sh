#!/bin/bash

if [ $# -lt 1 ]
then
  echo "Usage: $0 <time_in_seconds>"
  exit 1
fi
echo "*** "
echo "*** "
echo "*** "
echo "*** "
echo "***   starting scenario c1 $(date)"
echo "*** "
echo "*** "
echo "*** "
echo "*** "
./initLoadgenScen1.sh $1
echo "*** "
echo "*** "
echo "*** "
echo "*** "
echo "***   starting scenario c2 $(date)"
echo "*** "
echo "*** "
echo "*** "
echo "*** "

./initLoadgenScen2.sh $1
echo "*** "
echo "*** "
echo "*** "
echo "*** "
echo "***   starting scenario c3 $(date)"
echo "*** "
echo "*** "
echo "*** "
echo "*** "

#had to export again path to kubectl as it is not in path
#when running over the ssh

ssh -i /home/ubuntu/aws-markjaporeto.pem ubuntu@172.31.23.139 "export PATH=$PATH:/snap/bin;./initLoadgenScen3.sh $1"
echo "*** "
echo "*** "
echo "*** "
echo "*** "
echo "***   retreiving loadgen results $(date)"

./getLoadgenLog.sh

echo "*** "
echo "*** "
echo "*** "
echo "*** "
echo "***   finished run $(date)"
echo "*** "
echo "*** "
echo "*** "
echo "*** "
