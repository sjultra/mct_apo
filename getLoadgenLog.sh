#!/bin/bash

scp -i /home/ubuntu/aws-markjaporeto.pem ubuntu@172.31.23.139:/home/ubuntu/loadgen/* ./loadgen/
scp -i /home/ubuntu/aws-markjaporeto.pem ubuntu@172.31.23.139:/home/ubuntu/initLoadgenScen3.sh .
scp -i /home/ubuntu/aws-markjaporeto.pem ubuntu@172.31.23.139:/home/ubuntu/loadgen_s3.log .
