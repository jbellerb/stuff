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

COMMIT_YEAR=$(( $(date -j -f %s "$COMMIT_TIME" +"%G") - 2000 ))
COMMIT_WEEK=$(date -j -f %s "$COMMIT_TIME" +"%V")
COMMIT_WEEK=${COMMIT_WEEK#0} # remove leading zero

WEEK_START=$(date -j -v-mon -f %s "$COMMIT_TIME" +"%FT00:00:00+00")
COMMIT_COUNT=$(( $(git log --since="$WEEK_START" --oneline | wc -l) ))

echo $COMMIT_HASH
echo $CHANGE_ID
echo $TREE_DIRTY
echo $COMMIT_TIME
echo "$COMMIT_YEAR.$COMMIT_WEEK.$COMMIT_COUNT"
