"use client";

import { useCallback, useEffect, useState } from "react";
import {
  parseParticipantGroupsResponse,
  type ParticipantGroup,
  type ParticipantGroupInvitation,
} from "@/lib/ideas/participant-groups";

type Props = {
  onGroupsChange: (groups: ParticipantGroup[]) => void;
  highlightedInvitationId?: string;
};

async function postGroupAction(payload: Record<string, string>): Promise<unknown> {
  const response = await fetch("/api/groups", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const result: unknown = await response.json();
  if (!response.ok || typeof result !== "object" || result === null) {
    throw new Error("Group action failed.");
  }
  return result;
}

export default function ParticipantGroupsPanel({
  onGroupsChange,
  highlightedInvitationId,
}: Props) {
  const [groups, setGroups] = useState<ParticipantGroup[]>([]);
  const [invitations, setInvitations] = useState<ParticipantGroupInvitation[]>([]);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [inviteEmails, setInviteEmails] = useState<Record<string, string>>({});
  const [inviteLinks, setInviteLinks] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await fetch("/api/groups", { cache: "no-store" });
      const payload: unknown = await response.json();
      const parsed = parseParticipantGroupsResponse(payload);
      if (!response.ok || !parsed) throw new Error("Invalid groups response.");
      setGroups(parsed.groups);
      setInvitations(parsed.invitations);
      onGroupsChange(parsed.groups);
    } catch {
      setError("گروه‌ها و دعوت‌نامه‌ها بارگذاری نشدند. دوباره تلاش کنید.");
    } finally {
      setLoading(false);
    }
  }, [onGroupsChange]);

  useEffect(() => {
    const timer = window.setTimeout(() => void refresh(), 0);
    return () => window.clearTimeout(timer);
  }, [refresh]);

  async function runAction(payload: Record<string, string>): Promise<unknown> {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      const result = await postGroupAction(payload);
      if (
        typeof result === "object" &&
        result !== null &&
        "outcome" in result &&
        typeof result.outcome === "string" &&
        ["not_authorized", "not_found", "not_found_or_not_authorized",
          "target_not_member", "transfer_required", "group_unavailable",
          "already_member", "invalid_input"].includes(result.outcome)
      ) {
        const messages: Record<string, string> = {
          not_authorized: "اجازه انجام این کار را ندارید.",
          not_found: "گروه یا دعوت‌نامه دیگر در دسترس نیست.",
          not_found_or_not_authorized: "دعوت‌نامه پیدا نشد یا اجازه لغو آن را ندارید.",
          target_not_member: "مالکیت فقط به عضو پذیرفته‌شده گروه منتقل می‌شود.",
          transfer_required: "پیش از خروج، مالکیت گروه را به عضوی دیگر منتقل کنید.",
          group_unavailable: "این گروه دیگر امکان پذیرش عضو ندارد.",
          already_member: "شما هم‌اکنون عضو این گروه هستید.",
          invalid_input: "اطلاعات واردشده معتبر نیست.",
        };
        setNotice(messages[result.outcome] ?? "عملیات انجام نشد.");
      } else {
        setNotice("تغییرات گروه ذخیره شد.");
      }
      await refresh();
      return result;
    } catch {
      setError("عملیات گروه انجام نشد. اتصال را بررسی و دوباره تلاش کنید.");
      return null;
    } finally {
      setBusy(false);
    }
  }

  async function createGroup(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const result = await runAction({
      action: "create",
      name,
      description,
    });
    if (
      typeof result === "object" &&
      result !== null &&
      "outcome" in result &&
      result.outcome === "created"
    ) {
      setName("");
      setDescription("");
    }
  }

  async function inviteMember(event: React.FormEvent<HTMLFormElement>, group: ParticipantGroup) {
    event.preventDefault();
    const email = inviteEmails[group.id]?.trim() ?? "";
    const result = await runAction({ action: "invite", groupId: group.id, email });
    if (
      typeof result === "object" &&
      result !== null &&
      "invitation_id" in result &&
      typeof result.invitation_id === "string"
    ) {
      const inviteUrl = `${window.location.origin}/ideas?groupInvite=${encodeURIComponent(result.invitation_id)}`;
      setInviteLinks((current) => ({ ...current, [group.id]: inviteUrl }));
    }
  }

  return (
    <section
      aria-labelledby="groups-heading"
      className="mb-8 rounded-2xl border border-foreground/10 bg-white p-5 shadow-sm dark:bg-neutral-950 sm:p-8"
    >
      <div>
        <h2 id="groups-heading" className="text-xl font-semibold">
          گروه‌های مشارکت
        </h2>
        <p className="mt-2 text-sm leading-6 text-foreground/65">
          در کنار حساب فردی می‌توانید عضو چند گروه باشید. ایده‌ها، سهمیه سه‌تایی و کارنامه هر گروه مشترک است.
        </p>
      </div>

      {invitations.length > 0 && (
        <div className="mt-5 space-y-3">
          <h3 className="font-medium">دعوت‌نامه‌های دریافتی</h3>
          {invitations.map((invitation) => (
            <div
              key={invitation.id}
              className={`flex flex-wrap items-center justify-between gap-3 rounded-xl border p-4 ${
                invitation.id === highlightedInvitationId
                  ? "border-blue-500 bg-blue-50 dark:bg-blue-950/30"
                  : "border-foreground/10"
              }`}
            >
              <p className="text-sm">
                دعوت به عضویت در «{invitation.group_name}» · مهلت تا{" "}
                {new Date(invitation.expires_at).toLocaleDateString("fa-IR")}
              </p>
              <div className="flex gap-2">
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void runAction({ action: "accept", invitationId: invitation.id })}
                  className="min-h-10 rounded-lg bg-foreground px-4 text-sm text-background disabled:opacity-50"
                >
                  پذیرش
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void runAction({ action: "reject", invitationId: invitation.id })}
                  className="min-h-10 rounded-lg border border-foreground/20 px-4 text-sm disabled:opacity-50"
                >
                  رد دعوت
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {loading ? (
        <p role="status" className="mt-5 text-sm text-foreground/60">
          در حال بارگذاری گروه‌ها…
        </p>
      ) : (
        <div className="mt-5 space-y-4">
          {groups.map((group) => (
            <article key={group.id} className="rounded-xl border border-foreground/10 p-4 sm:p-5">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h3 className="font-semibold">{group.name}</h3>
                  {group.description && (
                    <p className="mt-1 whitespace-pre-wrap text-sm text-foreground/65">
                      {group.description}
                    </p>
                  )}
                  <p className="mt-2 text-xs text-foreground/60">
                    {group.role === "owner" ? "نماینده و مالک گروه" : "عضو گروه"} ·{" "}
                    {group.members.length} عضو ·{" "}
                    {group.dissolved_at ? "گروه منحل‌شده؛ فقط مشاهده" : "سهمیه مستقل: ۳ ایده"}
                  </p>
                </div>
                {group.role === "member" && !group.dissolved_at && (
                  <button
                    type="button"
                    disabled={busy}
                    onClick={() => void runAction({ action: "leave", groupId: group.id })}
                    className="min-h-9 rounded-lg border border-foreground/20 px-3 text-xs disabled:opacity-50"
                  >
                    خروج از گروه
                  </button>
                )}
              </div>

              <details className="mt-4">
                <summary className="cursor-pointer text-sm font-medium">
                  اعضا و مدیریت گروه
                </summary>
                <ul className="mt-3 space-y-2">
                  {group.members.map((member) => (
                    <li
                      key={member.user_id}
                      className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-foreground/[0.03] p-3 text-xs"
                    >
                      <span>
                        <span dir="ltr">{member.user_id}</span> ·{" "}
                        {member.role === "owner" ? "مالک" : "عضو پذیرفته‌شده"}
                      </span>
                      {group.role === "owner" && member.role === "member" && (
                          <span className="flex gap-2">
                            <button
                              type="button"
                              disabled={busy}
                              onClick={() => void runAction({
                                action: "transfer_ownership",
                                groupId: group.id,
                                memberId: member.user_id,
                              })}
                              className="underline disabled:opacity-50"
                            >
                              انتقال مالکیت
                            </button>
                            {!group.dissolved_at && (
                              <button
                                type="button"
                                disabled={busy}
                                onClick={() => void runAction({
                                  action: "remove_member",
                                  groupId: group.id,
                                  memberId: member.user_id,
                                })}
                                className="text-red-700 underline disabled:opacity-50"
                              >
                                حذف عضو
                              </button>
                            )}
                          </span>
                        )}
                    </li>
                  ))}
                </ul>

                {group.role === "owner" && !group.dissolved_at && (
                  <>
                    <form
                      onSubmit={(event) => void inviteMember(event, group)}
                      className="mt-4 flex flex-col gap-2 sm:flex-row"
                    >
                      <label className="sr-only" htmlFor={`invite-${group.id}`}>
                        ایمیل عضو جدید
                      </label>
                      <input
                        id={`invite-${group.id}`}
                        type="email"
                        required
                        value={inviteEmails[group.id] ?? ""}
                        onChange={(event) => setInviteEmails((current) => ({
                          ...current,
                          [group.id]: event.target.value,
                        }))}
                        placeholder="ایمیل عضو جدید"
                        className="min-h-10 min-w-0 flex-1 rounded-lg border border-foreground/20 bg-transparent px-3 text-sm"
                      />
                      <button
                        type="submit"
                        disabled={busy}
                        className="min-h-10 rounded-lg border border-foreground/20 px-4 text-sm disabled:opacity-50"
                      >
                        دعوت با ایمیل
                      </button>
                    </form>
                    {inviteLinks[group.id] && (
                      <p className="mt-3 break-all text-xs leading-5">
                        پیوند پذیرش را برای دعوت‌شده بفرستید:{" "}
                        <a
                          className="underline"
                          href={`mailto:${encodeURIComponent(inviteEmails[group.id] ?? "")}?subject=${encodeURIComponent(`دعوت به گروه ${group.name}`)}&body=${encodeURIComponent(inviteLinks[group.id])}`}
                        >
                          ارسال با ایمیل
                        </a>{" "}
                        · <span dir="ltr">{inviteLinks[group.id]}</span>
                      </p>
                    )}
                    {group.pending_invitations.map((invitation) => (
                      <p key={invitation.id} className="mt-2 text-xs text-foreground/60">
                        دعوت در انتظار: {invitation.email} ·{" "}
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => void runAction({
                            action: "revoke",
                            invitationId: invitation.id,
                          })}
                          className="underline"
                        >
                          لغو دعوت
                        </button>
                      </p>
                    ))}
                    <button
                      type="button"
                      disabled={busy}
                      onClick={() => {
                        if (window.confirm("انحلال گروه را تأیید می‌کنید؟ ایده‌های قبلی فقط قابل مشاهده خواهند بود.")) {
                          void runAction({ action: "dissolve", groupId: group.id });
                        }
                      }}
                      className="mt-4 min-h-9 rounded-lg border border-red-300 px-3 text-xs text-red-800 disabled:opacity-50"
                    >
                      انحلال گروه
                    </button>
                  </>
                )}
              </details>
            </article>
          ))}
          {groups.length === 0 && (
            <p className="rounded-xl border border-dashed border-foreground/20 p-5 text-center text-sm text-foreground/60">
              هنوز عضو گروهی نیستید. یک گروه بسازید یا دعوت‌نامه‌ای را بپذیرید.
            </p>
          )}
        </div>
      )}

      <form onSubmit={(event) => void createGroup(event)} className="mt-5 rounded-xl bg-foreground/[0.03] p-4">
        <h3 className="font-medium">ایجاد گروه</h3>
        <div className="mt-3 grid gap-3">
          <label className="text-sm">
            نام گروه
            <input
              required
              minLength={2}
              maxLength={120}
              value={name}
              onChange={(event) => setName(event.target.value)}
              className="mt-1 min-h-10 w-full rounded-lg border border-foreground/20 bg-transparent px-3"
            />
          </label>
          <label className="text-sm">
            توضیحات (اختیاری)
            <textarea
              maxLength={4000}
              rows={2}
              value={description}
              onChange={(event) => setDescription(event.target.value)}
              className="mt-1 w-full rounded-lg border border-foreground/20 bg-transparent p-3"
            />
          </label>
          <button
            type="submit"
            disabled={busy}
            className="min-h-10 justify-self-start rounded-lg bg-foreground px-4 text-sm text-background disabled:opacity-50"
          >
            ایجاد گروه
          </button>
        </div>
      </form>
      {notice && <p role="status" className="mt-4 text-sm">{notice}</p>}
      {error && (
        <div className="mt-4 flex flex-wrap items-center gap-3 text-sm text-red-800 dark:text-red-200">
          <p role="alert">{error}</p>
          <button type="button" onClick={() => void refresh()} className="underline">
            تلاش دوباره
          </button>
        </div>
      )}
    </section>
  );
}
