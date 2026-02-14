function fish_jj_prompt --description="Prompt function for Jujutsu"
    if not command -sq jj; or not jj root &>/dev/null
        return 1
    end

    jj log --no-graph -r @ -T '
    surround(
        " (",
        ")",
        separate(
            " ",
            coalesce(
                if(
                    description.first_line().substr(0, 18).starts_with(description.first_line()),
                    description.first_line().substr(0, 18),
                    description.first_line().substr(0, 15) ++ "..."
                ),
                surround(
                    raw_escape_sequence("\e[33m"),
                    raw_escape_sequence("\e[0m"),
                    "(no description set)",
                ),
            ),
            surround("(", ")", bookmarks.join(", ")),
        ),
    )
' --ignore-working-copy --color always
end
