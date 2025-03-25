#!/bin/bash

ssh aksnode sudo killall tardev-snapshotter
scp ~/repos/kata-containers/src/tardev-snapshotter/target/release/tardev-snapshotter aksnode:
