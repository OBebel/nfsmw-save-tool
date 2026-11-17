#!/usr/bin/env python3
"""Rename a Need for Speed: Most Wanted (2005) save profile without corrupting it.

Renaming the folder and the file is not enough: the player name is stored inside the
save, and the save ends with an MD5 of its own body. Edit the name without recomputing
that MD5 and the game rejects the save. That is why hex-editing a NFSMW save usually
"corrupts" it.

    MD5( bytes[0x34 : filesize-16] )  ==  last 16 bytes

Usage:
    python nfsmw_save.py list
    python nfsmw_save.py check  <path-to-save-file>
    python nfsmw_save.py rename <profile-folder-name> <NewName>
    python nfsmw_save.py rename <profile-folder-name> <NewName> --also-rename-folder

Saves live in:  <your Documents folder>\\NFS Most Wanted\\<Profile>\\<Profile>
(the folder and the file inside it share the same name; the game needs both to match)

Before EVERY rename, a full copy of the profile folder is made in
<your Documents folder>\\NFS Most Wanted - backups\\<Profile>_<YYYY-MM-DD_hh-mm-ss>
and its path is printed. If that copy fails, nothing is changed. No questions asked.
"""

import argparse
import ctypes
import datetime
import hashlib
import os
import re
import shutil
import subprocess
import sys

def documents_dir():
    # Ask Windows where Documents really is, like the window does: with OneDrive folder
    # backup, or a moved Documents, it is not %USERPROFILE%\Documents.
    try:
        buf = ctypes.create_unicode_buffer(260)
        if ctypes.windll.shell32.SHGetFolderPathW(None, 5, None, 0, buf) == 0:  # 5 = CSIDL_PERSONAL
            return buf.value
    except (AttributeError, OSError):
        pass
    return os.path.expanduser(r"~\Documents")


SAVES_DIR = os.path.join(documents_dir(), "NFS Most Wanted")

NAME_OFFSET = 0x5A31   # 23089 - player name, ASCII, NUL-terminated
NAME_FIELD = 35        # usable characters before the next record begins
MD5_START = 0x34       # the checksummed body starts here
MD5_LEN = 16           # ...and its MD5 occupies the final 16 bytes
EXPECTED_MAGIC = b"20CM"


def read(path):
    with open(path, "rb") as fh:
        return bytearray(fh.read())


def player_name(buf):
    end = buf.find(b"\x00", NAME_OFFSET)
    return buf[NAME_OFFSET:end].decode("ascii", errors="replace")


def stored_md5(buf):
    return bytes(buf[len(buf) - MD5_LEN:])


def computed_md5(buf):
    return hashlib.md5(bytes(buf[MD5_START:len(buf) - MD5_LEN])).digest()


def is_intact(buf):
    return stored_md5(buf) == computed_md5(buf)


# Besides the MD5, the header holds three CRC32s (EA's save container): [0x10] = CRC of
# 0x1C..0x23, [0x14] = CRC of 0x24 to the end (name and MD5 included), [0x18] = CRC of
# 0x00..0x17 (the header itself). Polynomial 0x04C11DB7, not reflected; the first 4 bytes
# go in inverted. Stored little-endian.
CRC_TABLE = []
for _i in range(256):
    _c = _i << 24
    for _ in range(8):
        _c = ((_c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if _c & 0x80000000 else (_c << 1) & 0xFFFFFFFF
    CRC_TABLE.append(_c)


def ea_crc32(data):
    c = int.from_bytes(data[:4], "big") ^ 0xFFFFFFFF
    for b in data[4:]:
        c = (((c << 8) & 0xFFFFFFFF) | b) ^ CRC_TABLE[c >> 24]
    return c ^ 0xFFFFFFFF


HEADER_CRCS = ((0x10, 0x1C, 0x24), (0x14, 0x24, None), (0x18, 0x00, 0x18))  # (where, from, to)


def set_header_crcs(buf):
    # In this order: the header CRC covers the other two.
    for where, start, end in HEADER_CRCS:
        buf[where:where + 4] = ea_crc32(bytes(buf[start:end])).to_bytes(4, "little")


def header_crcs_ok(buf):
    return len(buf) >= 0x28 and all(int.from_bytes(buf[where:where + 4], "little") == ea_crc32(bytes(buf[start:end]))
                                    for where, start, end in HEADER_CRCS)


def looks_like_save(buf):
    return len(buf) > NAME_OFFSET + NAME_FIELD and bytes(buf[:4]) == EXPECTED_MAGIC


def known_layout(buf):
    # A valid MD5 does NOT prove the name is at 0x5A31: another build could use the same MD5 with
    # another layout. The header size must match the file, and the field must look like the name
    # field: 1 to 35 printable ASCII characters, then only zeros to the end of its 36 bytes.
    # Otherwise writing there would damage other data - and the new MD5 would hide the damage.
    if len(buf) < 16 or int.from_bytes(buf[4:8], "little") != len(buf):
        return False
    field = bytes(buf[NAME_OFFSET:NAME_OFFSET + NAME_FIELD + 1])
    n = 0
    while n < len(field) and 32 <= field[n] <= 126:
        n += 1
    return 1 <= n <= NAME_FIELD and field[n:] == b"\x00" * (len(field) - n)


def taken_by_other(profile, new):
    # The folder or the in-game name of ANOTHER profile, ignoring case: the game would show two
    # profiles with the same name, and the other folder has no backup copy at all.
    for entry in os.listdir(SAVES_DIR):
        if entry.lower() == profile.lower():
            continue
        if entry.lower() == new.lower():
            return True
        try:
            buf = read(os.path.join(SAVES_DIR, entry, entry))
        except OSError:
            continue
        if looks_like_save(buf) and player_name(buf).lower() == new.lower():
            return True
    return False


def game_running():
    # With the game open, it writes the profile it has in memory over the change.
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq speed.exe", "/FO", "CSV", "/NH"],
                             capture_output=True, stdin=subprocess.DEVNULL).stdout.decode("ascii", "replace")
    except OSError:
        return False
    return any(line.lower().startswith('"speed.exe"') for line in out.splitlines())


def backups_dir():
    # Next to the saves folder, never inside it: the game treats every folder in there
    # as a profile.
    return SAVES_DIR + " - backups"


def make_full_copy(folder):
    """Copy the whole profile folder to <saves> - backups/<profile>_<date_time>.

    Never overwrites an older copy (same second gets _2, _3...). Every file is read back
    and compared. Any failure raises, and the caller changes nothing."""
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    base = os.path.join(backups_dir(), "%s_%s" % (os.path.basename(folder), stamp))
    dest, n = base, 2
    while os.path.exists(dest):
        dest, n = "%s_%d" % (base, n), n + 1
    shutil.copytree(folder, dest)  # refuses an existing dest
    for root, _dirs, files in os.walk(folder):
        for f in files:
            src = os.path.join(root, f)
            dst = os.path.join(dest, os.path.relpath(src, folder))
            if not os.path.isfile(dst) or read(src) != read(dst):
                raise OSError("the copy of %s does not match the original" % src)
    return dest


def cmd_list(_args):
    if not os.path.isdir(SAVES_DIR):
        sys.exit("Saves folder not found: %s" % SAVES_DIR)
    print("Saves in %s\n" % SAVES_DIR)
    print("  %-26s %-20s %-8s %s" % ("folder", "name inside", "intact", "modified"))
    print("  " + "-" * 72)
    found = 0
    for entry in sorted(os.listdir(SAVES_DIR)):
        path = os.path.join(SAVES_DIR, entry, entry)
        if not os.path.isfile(path):
            print("  %-26s (no save file with a matching name - the game ignores it)" % entry)
            continue
        # A locked or unreadable save gets its own line; the rest are still listed.
        try:
            buf = read(path)
        except OSError as e:
            print("  %-26s (could not read the file: %s)" % (entry, e.strerror or e))
            continue
        if not looks_like_save(buf):
            print("  %-26s (not a NFSMW save)" % entry)
            continue
        if not known_layout(buf):
            print("  %-26s (unknown layout - the name is not where this tool expects it)" % entry)
            continue
        found += 1
        when = datetime.datetime.fromtimestamp(os.path.getmtime(path))
        print("  %-26s %-20s %-8s %s"
              % (entry, repr(player_name(buf)), "yes" if is_intact(buf) else "NO",
                 when.strftime("%Y-%m-%d %H:%M")))
    if not found:
        print("\n  No usable saves found.")


def cmd_check(args):
    buf = read(args.path)
    print("file      : %s" % args.path)
    print("size      : %d bytes" % len(buf))
    print("magic     : %r %s" % (bytes(buf[:4]), "OK" if bytes(buf[:4]) == EXPECTED_MAGIC else "UNEXPECTED"))
    known = looks_like_save(buf) and known_layout(buf)
    print("name      : %s" % (repr(player_name(buf)) if known else
                             "? (unknown layout - the name is not where this tool expects it)"))
    print("md5 stored: %s" % stored_md5(buf).hex())
    print("md5 actual: %s" % computed_md5(buf).hex())
    print("intact    : %s" % ("yes" if is_intact(buf) else "NO - this save is already broken"))
    print("header crc: %s" % ("ok" if header_crcs_ok(buf) else
                             "stale" + (" (a rename with this tool rewrites them)" if known and is_intact(buf) else "")))


def cmd_rename(args):
    # Same rule as the window: trimmed, 1 to 35 characters, printable ASCII (32..126).
    new = args.new_name.strip()
    if not new:
        sys.exit("Write the new name - it cannot be empty.")
    if len(new) > NAME_FIELD:
        sys.exit("Name too long: %d characters, the field holds %d." % (len(new), NAME_FIELD))
    if any(ord(c) < 32 or ord(c) > 126 for c in new):
        sys.exit("ASCII only - the field does not store accented characters.")
    # With --also-rename-folder the name is also a folder name: path symbols, "..", CON
    # or a trailing dot would fail after the save was written, or move it out of its folder.
    if args.also_rename_folder and (any(c in '\\/:*?"<>|' for c in new) or new.endswith((".", " "))
                                    or re.match(r"(?i)(CON|PRN|AUX|NUL|COM\d|LPT\d)(\..*)?$", new)):
        sys.exit("%r cannot be a folder name (no \\ / : * ? \" < > |, no trailing dot, no CON/NUL). "
                 "Pick another name or drop --also-rename-folder." % new)

    folder = os.path.join(SAVES_DIR, args.profile)
    path = os.path.join(folder, args.profile)
    if not os.path.isfile(path):
        sys.exit("Save not found: %s" % path)

    buf = read(path)
    if not looks_like_save(buf):
        sys.exit("This does not look like a NFSMW save (magic mismatch).")
    if not is_intact(buf):
        sys.exit("This save is ALREADY corrupted (checksum mismatch). Refusing to touch it.")
    if not known_layout(buf):
        sys.exit("This save does not have the known layout (the name is not where it should be). Refusing to touch it.")
    if taken_by_other(args.profile, new):
        sys.exit("There is already a profile called %r. Pick another name." % new)
    # With --also-rename-folder the file is renamed INSIDE the folder: a file with the new
    # name (the .bak, for example) would be overwritten.
    if args.also_rename_folder and new.lower() != args.profile.lower() and os.path.exists(os.path.join(folder, new)):
        sys.exit("The profile folder already has a file called %r, and --also-rename-folder would overwrite it. "
                 "Pick another name." % new)
    if game_running():
        sys.exit("The game is running (speed.exe). Close it and run this again. NOTHING was changed.")

    old = player_name(buf)
    print("save : %s" % path)
    print("name : %r -> %r" % (old, new))

    # A full copy of the profile folder before EVERY change (the .bak below is only
    # written the first time). No copy, no change.
    try:
        copy = make_full_copy(folder)
    except OSError as e:
        sys.exit("Could not make the backup copy, so NOTHING was changed.\n%s\n"
                 "(If a partial copy was left in %s, do not restore from it.)" % (e, backups_dir()))
    print("backup copy: %s" % copy)

    backup = path + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print("backup: %s" % backup)

    # Fixed-width field: write the name, zero the remainder. Nothing shifts,
    # so no offset anywhere else in the file changes.
    buf[NAME_OFFSET:NAME_OFFSET + NAME_FIELD + 1] = new.encode("ascii").ljust(NAME_FIELD + 1, b"\x00")

    # The step everyone misses.
    buf[len(buf) - MD5_LEN:] = computed_md5(buf)
    # ...and after it (the CRC at 0x14 covers the MD5), the header CRCs.
    set_header_crcs(buf)

    try:
        with open(path, "wb") as fh:
            fh.write(bytes(buf))
    except OSError as e:
        # Only the disk says whether the save is still whole: read it back.
        try:
            disk = read(path)
        except OSError:
            disk = None
        if disk is not None and looks_like_save(disk) and is_intact(disk):
            if player_name(disk) == old:
                sys.exit("Could not write the save (%s).\nThe save on disk is intact, with the name %r inside: "
                         "NOTHING was changed, no need to restore." % (e, old))
            sys.exit("Could not write the save (%s).\nThe save on disk is intact, with the name %r inside: "
                     "no need to restore." % (e, player_name(disk)))
        sys.exit("Could not write the save (%s).\nSomething went wrong. With the game closed, copy what is inside\n  %s\n"
                 "back into\n  %s\n(the .bak is there too: %s)" % (e, copy, folder, backup))

    # Verify by reading back from disk, never from memory.
    check = read(path)
    ok = player_name(check) == new and is_intact(check) and header_crcs_ok(check) and len(check) == len(buf)
    print()
    print("name inside : %r %s" % (player_name(check), "OK" if player_name(check) == new else "FAILED"))
    print("checksum    : %s" % ("OK" if is_intact(check) else "FAILED"))
    print("header crc  : %s" % ("OK" if header_crcs_ok(check) else "FAILED"))
    print("size        : %d bytes %s" % (len(check), "OK" if len(check) == len(buf) else "CHANGED!"))

    if not ok:
        sys.exit("\nSomething went wrong. With the game closed, copy what is inside\n  %s\n"
                 "back into\n  %s\n(the .bak is there too: %s)" % (copy, folder, backup))

    folder_ok = True
    if args.also_rename_folder:
        target = os.path.join(SAVES_DIR, new)
        if new.lower() == args.profile.lower():
            # Its own folder: only upper/lower case changes (or nothing), and to Windows that is the same name.
            print("\nThe folder is already called %r%s - leaving folder and file names alone."
                  % (args.profile, "" if new == args.profile else " (to Windows, upper and lower case are the same name)"))
            print("The in-game name is already correct.")
        elif os.path.exists(target):
            print("\nFolder %r already exists - leaving folder and file names alone." % new)
            print("The in-game name is already correct.")
        else:
            # The folder goes first, as a plain rename (shutil.move would copy and then delete): if
            # anything in it is in use, nothing moves. If the file fails after that, the folder goes back.
            moved = False
            try:
                os.rename(folder, target)
                moved = True
                os.rename(os.path.join(target, args.profile), os.path.join(target, new))
                folder_ok = os.path.isfile(os.path.join(target, new))
                print("\nfolder/file renamed to %r  %s" % (new, "OK" if folder_ok else "FAILED"))
            except OSError as e:
                folder_ok = False
                print("\nfolder/file NOT renamed: %s" % e)
                if moved:
                    try:
                        os.rename(target, folder)
                    except OSError:
                        print("And the folder did not go back: rename %s to %r by hand." % (target, args.profile))

    if folder_ok:
        print("\nDone. Open the game and check the profile name.")
    else:
        print("\nThe name inside the save was changed, but the folder failed (see above).")
    print("The copy from before this change is in %s" % copy)
    if not folder_ok:
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("list", help="list every save and whether it is intact")

    c = sub.add_parser("check", help="inspect one save file")
    c.add_argument("path")

    r = sub.add_parser("rename", help="change the player name inside a save")
    r.add_argument("profile", help="the profile folder name")
    r.add_argument("new_name")
    r.add_argument("--also-rename-folder", action="store_true",
                   help="also rename the folder and the file to match")

    args = p.parse_args()
    if args.cmd == "list":
        cmd_list(args)
    elif args.cmd == "check":
        cmd_check(args)
    elif args.cmd == "rename":
        cmd_rename(args)
    else:
        p.print_help()


if __name__ == "__main__":
    main()
