#!/usr/bin/env bash

git push origin && git push aliyun

git tag -d release-vdev
git tag release-vdev
git push origin -f release-vdev
git push aliyun -f release-vdev
