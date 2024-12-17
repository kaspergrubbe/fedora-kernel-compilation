#!/bin/bash
rsync -avz --exclude='.*' --progress . root@snowflake.tailee3ed.ts.net:/root/kernel/
