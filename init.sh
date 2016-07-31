#!/bin/bash

curPath=`dirname $0`
cd $curPath
prjHome=`pwd`

/usr/local/bin/rigger -rconfDir=$prjHome/conf/rigger/ prj_home=$prjHome

docker exec sphinx-latest bash -c "cd $prjHome;make html"
