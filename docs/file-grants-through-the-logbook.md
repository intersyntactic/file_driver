# File grants through the logbook

A design for how the airlock gets a granted file action to the file driver
without a socket of its own into it, while the logbook stays true about what
the driver did. Not built yet. It spans the airlock, a new program, the file
driver and infra; each part is built in its own repo.

## What is true today

- Only the `readers` group can reach the logbook's read socket, which sends
  every entry. That is the airlock, the docking station and loop-launcher.
  Neither a suit nor an agent loop is a member.
- A loop reads only its own feed: loop-launcher serves
  `/run/intersyntactic-loop-launcher/loop-N/feed.sock`, a folder owned by
  group `loop-N`, answering `subscribe` with that loop's trajectory alone.
  Its `TrajectoryRouter` follows an outcome's `proposed` back to the
  proposal's chain to find the trajectory an outcome belongs to.
- The file driver runs as `suit-N`, in `file-driver@suit-N`, listening on
  `/run/file/suit-N/driver.sock`, and answers only the airlock's user.
- The agent's programs also run as `suit-N`, in `program-contained@suit-N`
  or `program-open@suit-N`. `ProtectSystem=strict` makes `/run` read-only
  to them, so they cannot replace the driver's socket, and the driver
  refuses their requests. The kernel cannot tell suit-N's driver from
  suit-N's agent; the systemd unit is what tells them apart.
- The airlock's decision entry (`AirlockDecisionOnAction.kind`) is a line
  for a person to read; nothing parses it. Its outcome
  (`outcome-of-proposed-action`) extends the decision's chain.
- The airlock has no file client (main at b43c854), so no file action is
  carried out yet. Nothing has to migrate.

## The rule this design keeps

The logbook is true about what the driver did, not only about what the
airlock granted. Only the file driver for a grant's suit can answer that
grant, and only once.

## The shape

    loop ──proposal──▶ logbook ◀──grant── airlock
                         │  ▲
                (readers)│  │(senders) outcome
                         ▼  │
                   file grant feed  ── /run/file-grant-feed/suit-N/feed.sock
                         ▲  │            (hidden from program units;
                  answer │  │ grant       caller must be file-driver@suit-N)
                         │  ▼
                   file-driver@suit-N

1. **The airlock writes a grant.** After its decision, for a file action it
   allowed, it writes a new kind, `file-request-granted`, extending the
   decision's chain. Body: `{"proposed", "trajectory", "request"}`, where
   `request` is `encodeFileRequest` from is_file_request_vocabulary. It
   names no suit: the suit is the one the logbook's
   `users-assigned-to-trajectory` gives that trajectory, so there is no
   second record of it to disagree with. The airlock writes no outcome for
   a grant.
2. **The file grant feed delivers it.** A new program, its own user
   `file-grant-feed`, in groups `readers` and `senders`. It subscribes to
   `users-assigned-to-trajectory`, `trajectory-closed`, `mission-ended`,
   `file-request-granted` and `outcome-of-proposed-action`. It keeps, for
   each open trajectory, its suit, and for each grant, whether an outcome
   already extends it. It serves `/run/file-grant-feed/suit-N/feed.sock`,
   one per suit, and sends each unanswered grant for that suit's
   trajectories to whoever is connected there.
3. **The driver answers on the same connection.** `file-driver@suit-N`
   connects instead of listening. For each grant, it carries out the
   request as it does today and sends back the `Outcome`, encoded as today,
   naming the grant.
4. **The feed writes the outcome.** It writes `outcome-of-proposed-action`
   with `previous` set to the grant, so the outcome extends the grant's
   chain. The logbook's tip check makes this once only: a second outcome
   for the same grant names a `previous` that is no longer the tip, and is
   refused. Its body is exactly `outcomeOfProposedActionToJson(proposed,
   result)`, with `proposed` copied from the grant, so it names the loop's
   own proposal, never the grant. loop-launcher's `TrajectoryRouter` routes
   an outcome by that body alone (it never reads `previous`), and a body
   with any other key is one `readOutcomeOfProposedAction` refuses and no
   loop receives. agent_loop matches the outcome to its waiting proposal by
   the same id.

loop-launcher routes the grant itself to the trajectory's loop feed too,
since the grant names its trajectory. No loop receives it: agent_loop
subscribes only to the kinds it names, which `file-request-granted` is not,
and the feed sends only the kinds asked for.

## Who may answer: the unit is the identity

Two walls, both set up by systemd, so neither depends on the agent
behaving:

- **The agent cannot see the feed.** `program-contained@` and
  `program-open@` list `/run/file-grant-feed` under `InaccessiblePaths=`;
  `file-driver@` does not. The folder `suit-N` is group `suit-N`, `0750`.
- **The feed checks the caller's unit, not only its user.** On each
  connection it reads the caller's user and process from the kernel, then
  the process's cgroup, and serves only `file-driver@suit-N.service` on
  `suit-N`'s socket. No process can move itself into another unit's
  cgroup: systemd places it, and `ProtectControlGroups=true` keeps the
  cgroup tree read-only to every unit involved. Where the kernel offers it
  (`SO_PEERPIDFD`, Linux 6.5), the feed reads the cgroup through a handle
  to the process, so a process id reused between the check and the read
  cannot fool it; without it, the check reads `/proc/<pid>/cgroup` and
  checks the user again afterwards.

Without these two walls, putting grants on a feed suit-N can read would let
the agent's own code take a write grant and answer "Wrote" without writing,
and the logbook would record a write that never happened.

The driver does not get a user of its own. Files it writes would then be
owned by that user rather than the suit, breaking infra's proof step "the
file is suit-16's". Reads would also depend on group permissions in the
home. The unit check already separates the driver from the agent.

## When a driver stops partway

The feed records that it delivered a grant only in memory. If the driver's
connection drops after delivery and before an answer, the feed writes
`StoppedPartway` ("the file driver stopped before answering") for that
grant, and does not deliver it again: it cannot know whether the write ran.
This is what the airlock's own caller answers today when no answer comes.
A grant the feed never delivered (no driver connected, or the feed itself
restarted) is delivered when a driver for its suit connects. A grant whose
trajectory closes first is answered `NothingRan`.

If the feed restarts after delivering but before writing the outcome, it
cannot tell that it delivered. It delivers again, so a write may run twice.
A write of the same text to the same path leaves the same file, except
`replaced`, which the second run reports as true. This is the one gap, and
it is the same gap the airlock has today when it restarts between running
an action and recording it.

## What each repo builds

- **airlock**: a `file-request-granted` writer for allowed file actions,
  and no outcome for them. The sender table gives `file-request-granted`
  to `airlock` only.
- **file grant feed** (new repo): the program above. Its routing is
  loop-launcher's `TrajectoryRouter` and `LoopFeeds` again, keyed by suit
  instead of loop user. The rule for which entries belong to which
  trajectory lives in one place, so it is shared, not copied: a small
  package holding `TrajectoryRouter` and a socket feed per key, which
  loop_launcher and the file grant feed both depend on. loop_launcher
  itself never holds the right to write outcomes. Taking that package out
  of loop_launcher is a loop_launcher change, which needs Nick's yes.
- **file_driver**: connects to `FILE_DRIVER_FEED` instead of listening on
  `FILE_DRIVER_SOCKET`; the caller check moves to the feed's side. The
  request and answer encodings do not change.
- **infra**: user `file-grant-feed` in `readers` and `senders`; the sender
  table gives it `outcome-of-proposed-action`; `InaccessiblePaths=` on both
  program units; tmpfiles for `/run/file-grant-feed/suit-N`; a proof that a
  process in `program-open@suit-16` can neither open the feed nor answer a
  grant.
- **logbook**: nothing.

## Checked on the box

- enspyr-syd runs Linux 6.17, so the feed can use `SO_PEERPIDFD`.
- A read-only `/run` does not stop `connect()` to a socket already there: a
  transient unit with program-open@'s sandbox connected to a listener
  under `/run`. A process running as suit-N passes the permission check on
  a `suit-N` `0660` socket, so the only thing stopping it is the listener
  checking who the caller is. That is why the feed must check the caller's
  unit, and why its folder must also be hidden.

## To check on the box before building

- That `InaccessiblePaths=` on a program unit hides the feed folder from a
  program it starts, and that `ProtectControlGroups=true` is on in every
  unit that runs as a suit.
