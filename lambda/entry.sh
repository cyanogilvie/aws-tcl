#!/bin/sh

if [ -z "${AWS_LAMBDA_RUNTIME_API}" ]; then
    exec /usr/local/bin/aws-lambda-rie /usr/local/bin/tclsh /usr/local/bin/awslambdaric $*
else
    exec /usr/local/bin/tclsh /usr/local/bin/awslambdaric $*
fi
