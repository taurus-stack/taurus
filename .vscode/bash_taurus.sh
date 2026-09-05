#!/bin/bash
set -m
# 加载用户默认的 .bashrc
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi

# 激活 taurus 环境
conda activate taurus
