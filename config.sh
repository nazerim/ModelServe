# Single source of truth for the serving scripts. Sourced by serve.sh,
# start.sh and test.sh; the *-test.sh harnesses read $PORT from the environment.
# An env override still wins:  PORT=9000 <repo>/start.sh
export PORT="${PORT:-8000}"
export HOST="${HOST:-127.0.0.1}"
export MODEL_DIR="${MODEL_DIR:-$HOME/.models}"
