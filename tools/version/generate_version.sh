#!/usr/bin/env sh

git() {
    command git "$@" || { echo "Failed to find commit" >&2; exit 1; }
}

COMMIT_HASH=$(git rev-parse --verify HEAD)

# parse the commit headers
while IFS= read -r line
do
    if test -z "$line"
    then
        break
    fi

    header=${line%% *}
    val=${line#* }

    case $header in
    change-id) CHANGE_ID=$val ;;
    committer)
        val=${val% *}
        COMMIT_TIME=${val##* }
        ;;
    esac
done <<EOF
$(git cat-file commit HEAD)
EOF

# check if the tree is dirty
if ! (git update-index --refresh; git diff-index --quiet HEAD --) > /dev/null 2>&1
then
    TREE_DIRTY="-dirty"
fi

COMMIT_YEAR=$(( $(date -u -d "@$COMMIT_TIME" +"%G") - 2000 ))
COMMIT_WEEK=$(date -u -d "@$COMMIT_TIME" +"%V")
COMMIT_WEEK=${COMMIT_WEEK#0} # remove leading zero

DAYS_SINCE_MON=$(( $(date -u -d "@$COMMIT_TIME" +%u) - 1 ))
if test "${DAYS_SINCE_MON}" -eq 0
then
    WEEK_START=$(date -u -d "@$COMMIT_TIME" +"%FT00:00:00+00")
else
    WEEK_START=$(date -u -d "@$COMMIT_TIME -${DAYS_SINCE_MON} days" +"%FT00:00:00+00")
fi
COMMIT_COUNT=$(( $(git log --since="$WEEK_START" --oneline | wc -l) ))

echo $COMMIT_HASH
echo $CHANGE_ID
echo $TREE_DIRTY
echo $COMMIT_TIME
echo "$COMMIT_YEAR.$COMMIT_WEEK.$COMMIT_COUNT"
