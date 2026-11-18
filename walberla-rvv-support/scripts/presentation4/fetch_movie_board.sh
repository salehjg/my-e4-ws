#!/usr/bin/env bash
# Laptop: fetch the board's film (cavity_movie_board.sh) into the repository and compare it with the x86 film.
#
# Usage: bash scripts/presentation4/fetch_movie_board.sh [ssh host, default bananapi]
# Needs: the board job ended with MOVIE PASS (logs/movie.log); the x86 film's cache with f64 middle planes,
#   build/presentation4-x86-upstream/cavity-movie-work/slices.npz (python3 scripts/presentation4/cavity_movie.py).
# Copies:
#   board <base>/presentation4/movie/*          -> docs/presentation4/figures/cavity-movie-board/
#   board logs/movie.log, cavity-movie-board.log -> docs/presentation4/board-logs/board/
#   board movie-work/slices.npz                  -> build/presentation4-board-movie/slices.npz (ignored by git)
# then checks the sha256 of every copied file against the board's, and runs compare_movies.py (x86 against board).
set -euo pipefail

H="${1:-bananapi}"
R=/home/bananapi/saleh/presentation4
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
OUT="${REPO}/docs/presentation4/figures/cavity-movie-board"
LOGS="${REPO}/docs/presentation4/board-logs/board"
WORK="${REPO}/build/presentation4-board-movie"

ssh "${H}" "grep -q '^MOVIE PASS' ${R}/logs/movie.log" \
    || { echo "the board film did not pass (or is not finished): see ${R}/logs/movie.log on ${H}"; exit 1; }
mkdir -p "${OUT}" "${WORK}"
scp -q "${H}:${R}/movie/*" "${OUT}/"
scp -q "${H}:${R}/logs/movie.log" "${H}:${R}/logs/cavity-movie-board.log" "${LOGS}/"
scp -q "${H}:${R}/movie-work/slices.npz" "${WORK}/"

#   every copied file byte for byte as on the board
remote="$(ssh "${H}" "cd ${R} && sha256sum movie/* logs/movie.log logs/cavity-movie-board.log movie-work/slices.npz" \
    | sed -E 's#  (movie|logs|movie-work)/#  #' | sort)"
local_="$( (cd "${OUT}" && sha256sum ./*; cd "${LOGS}" && sha256sum movie.log cavity-movie-board.log; \
    cd "${WORK}" && sha256sum slices.npz) | sed -E 's#  \./#  #' | sort)"
if [[ "${remote}" == "${local_}" ]]; then
    echo "copied $(wc -l <<< "${local_}") files, sha256 equal on board and laptop"
else
    echo "SHA256 MISMATCH"; diff <(echo "${remote}") <(echo "${local_}") || true; exit 1
fi

python3 "${HERE}/compare_movies.py" \
    "${REPO}/docs/presentation4/board-logs/x86/cavity-movie.log" "${REPO}/build/presentation4-x86-upstream/cavity-movie-work/slices.npz" \
    "${LOGS}/cavity-movie-board.log" "${WORK}/slices.npz"
