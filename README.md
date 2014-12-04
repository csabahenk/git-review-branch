# What is this?

`git-review-branch` is an improvement upon

    git review --compare <change>,<patchset>[,<patchset>]

While the above feature is an ephemeral differential
view of two patchsets of a change, `git-review-branch`
builds a permanent branch that includes all patchsets
of a change, rebased to the specified base. (Well, at
least all for which this is possible without conflict).

If not specified, the base will be the parent of the
latest patchset.

The branch can be updated later on.

# How to install?

TL;DR:
- Needs ruby \>= 1.9.\*
- needs git
- use in place
- if you don't want do deal with deps,
  just use `--jsonhack`

Elaborate version:

There are two optional dependencies:

- yajl gem, avaliable with `gem install yajl-ruby`
  for sound JSON parsing (in lack of that, you can
  enable a workaround with the `--jsonhack` option);
- mustache gem, available with `gem install moustache`,
  if you want to use mustache templates for naming
  the branch.

# How to use?

Starting with it, use `-v`/`--verbose` to see what it does.

Suggested usage:

First run:

    $ git-review-branch -v -b <change-id>

where `<change-id>` can be either of the style
`I9ac0a7be8e942c83759e08cc1d16f332c08960ff` or
`1246543`.
 
This will get the patchsets of the change and checks you
out on a (hopefully) conventionally named brach.

Updating: 

If you are on another branch:

    $ git-review-branch -v -b <change-id>

again.

If you are on the review branch:

    $ git-review-branch -v -b

suffices..

If you want to have your branch rebased to
latest commit:

    $ git-review-branch -v -b --force

I hope this is good enough to get you going, rest
is subtleties.

Enjoy
Csaba Henk
