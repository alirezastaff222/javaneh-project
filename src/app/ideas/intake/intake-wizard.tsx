"use client";

import Link from "next/link";
import { useState } from "react";

const educationOptions = [
  "زیر دیپلم",
  "دیپلم",
  "کاردانی",
  "کارشناسی",
  "کارشناسی ارشد",
  "دکتری",
  "تحصیلات حوزوی",
  "مورد دیگر",
  "ترجیح می‌دهم پاسخ ندهم",
];

const provinces = [
  "آذربایجان شرقی", "آذربایجان غربی", "اردبیل", "اصفهان", "البرز", "ایلام",
  "بوشهر", "تهران", "چهارمحال و بختیاری", "خراسان جنوبی", "خراسان رضوی",
  "خراسان شمالی", "خوزستان", "زنجان", "سمنان", "سیستان و بلوچستان",
  "فارس", "قزوین", "قم", "کردستان", "کرمان", "کرمانشاه", "کهگیلویه و بویراحمد",
  "گلستان", "گیلان", "لرستان", "مازندران", "مرکزی", "هرمزگان", "همدان", "یزد",
];

const environmentOptions = [
  "خانه یا ساختمان",
  "محله، روستا یا شهر",
  "مدرسه یا دانشگاه",
  "محل کار",
  "اداره یا سازمان دولتی",
  "فضای مجازی",
  "جای دیگری",
  "مطمئن نیستم",
];

const outcomeOptions = [
  "منابع، هزینه یا زمان کمتری هدر می‌رود.",
  "به تولیدکنندگان داخلی کمک می‌کند.",
  "همیاری و کمک مردم به یکدیگر آسان‌تر می‌شود.",
  "مردم در شرایط فشار اقتصادی بیشتر از یکدیگر حمایت می‌کنند.",
  "آگاهی، امید یا مشارکت مردم افزایش می‌یابد.",
  "افراد و گروه‌های آسیب‌پذیر توانمندتر می‌شوند.",
  "نتیجهٔ دیگری دارد.",
  "مطمئن نیستم.",
];

const axisOptions = [
  {
    title: "بهینه‌سازی مصرف و کاهش اتلاف منابع با مشارکت مردم",
    description: "راه‌هایی برای استفادهٔ سنجیده‌تر از منابع و کم‌کردن هدررفت با همراهی جامعه.",
    example: "مثال: شبکهٔ محلی برای تعمیر، استفادهٔ دوباره یا به‌اشتراک‌گذاری وسایل.",
  },
  {
    title: "تقویت فرهنگ و کنش مردمی در حمایت از تولید داخلی",
    description: "ایده‌هایی که شناخت، اعتماد و دسترسی مردم به تولیدکنندگان داخلی را بیشتر می‌کنند.",
    example: "مثال: معرفی شفاف تولیدکنندگان محلی و آسان‌کردن خرید مستقیم از آن‌ها.",
  },
  {
    title: "توسعهٔ یاریگری و الگوهای همکاری مردمی در اقتصاد",
    description: "الگوهای داوطلبانه و جمعی برای همکاری، تبادل مهارت یا پشتیبانی اقتصادی.",
    example: "مثال: گروه همیاری محله برای تبادل خدمات و مهارت‌های کاربردی.",
  },
  {
    title: "ارتقای تاب‌آوری اجتماعی در مواجهه با فشارهای اقتصادی",
    description: "راه‌هایی برای تقویت توان خانواده‌ها و جامعه در عبور از دشواری‌های اقتصادی.",
    example: "مثال: گروه پشتیبان محلی برای دسترسی به راهنمایی و منابع قابل‌اعتماد.",
  },
  {
    title: "نوآوری در ارتباطات، روایت و بسیج اجتماعی",
    description: "شیوه‌های تازه برای شنیده‌شدن مسائل و دعوت مردم به مشارکت مؤثر.",
    example: "مثال: روایت‌های کوتاه محلی که مردم را به یک اقدام جمعی مشخص دعوت می‌کند.",
  },
  {
    title: "نوآوری در الگوهای توانمندسازی و حمایت از اقشار آسیب‌پذیر",
    description: "راهکارهایی برای افزایش دسترسی، استقلال و فرصت مشارکت گروه‌های آسیب‌پذیر.",
    example: "مثال: پیوند افراد با فرصت‌های آموزش، مشاوره یا پشتیبانی نزدیک به محل زندگی.",
  },
];

const audienceOptions = [
  "شهروند علاقه‌مند",
  "دانش‌آموز یا دانشجو",
  "پژوهشگر یا استاد",
  "فعال اجتماعی یا فرهنگی",
  "عضو گروه مردمی یا سمن",
  "صاحب ایده یا کسب‌وکار",
  "متخصص یا شاغل حرفه‌ای",
  "مورد دیگر",
];

const titles = [
  "شرح مسئله و زمینهٔ ایده",
  "آخرین مقطع تحصیلی",
  "اطلاعات تماس و محل سکونت",
  "یک نمونهٔ واقعی از مسئله",
  "محیط مشاهدهٔ مسئله",
  "تغییر قابل‌مشاهده",
  "اقدام پیشنهادی",
  "نتایج مورد انتظار",
  "محور رویداد",
  "عنوان ایده",
  "اطلاعات تکمیلی (اختیاری)",
  "مرور و تأیید",
];

type Answers = {
  ideaDescription: string;
  education: string;
  educationOther: string;
  email: string;
  province: string;
  city: string;
  issueExample: string;
  environment: string;
  environmentOther: string;
  visibleChange: string;
  proposedAction: string;
  outcomes: string[];
  otherOutcome: string;
  axes: string[];
  title: string;
  fieldOfStudy: string;
  audience: string;
  audienceOther: string;
  futureUpdates: boolean;
};

const emptyAnswers: Answers = {
  ideaDescription: "",
  education: "",
  educationOther: "",
  email: "",
  province: "",
  city: "",
  issueExample: "",
  environment: "",
  environmentOther: "",
  visibleChange: "",
  proposedAction: "",
  outcomes: [],
  otherOutcome: "",
  axes: [],
  title: "",
  fieldOfStudy: "",
  audience: "",
  audienceOther: "",
  futureUpdates: false,
};

function ChoiceCard({
  label,
  selected,
  onClick,
  radio = false,
  description,
  example,
}: {
  label: string;
  selected: boolean;
  onClick: () => void;
  radio?: boolean;
  description?: string;
  example?: string;
}) {
  return (
    <button
      type="button"
      role={radio ? "radio" : "checkbox"}
      aria-checked={selected}
      onClick={onClick}
      className={`intake-choice ${selected ? "intake-choice-selected" : ""}`}
    >
      <span className="intake-choice-indicator" aria-hidden="true">{selected ? "✓" : ""}</span>
      <span className="min-w-0 flex-1">
        <span className="block text-sm font-medium leading-6">{label}</span>
        {description && <span className="mt-1 block text-xs leading-5 text-white/55">{description}</span>}
        {example && <span className="mt-1.5 block text-xs leading-5 text-emerald-100/55">{example}</span>}
      </span>
    </button>
  );
}

export default function IntakeWizard({ initialIdea }: { initialIdea: string }) {
  const [step, setStep] = useState(0);
  const [answers, setAnswers] = useState<Answers>({
    ...emptyAnswers,
    ideaDescription: initialIdea,
  });
  const [acceptedTerms, setAcceptedTerms] = useState(false);
  const [error, setError] = useState("");
  const [finalChoice, setFinalChoice] = useState("");

  function update<K extends keyof Answers>(key: K, value: Answers[K]) {
    setAnswers((current) => ({ ...current, [key]: value }));
    setError("");
  }

  function toggleOutcome(option: string) {
    const currentChoices = answers.outcomes.filter((choice) => choice !== "مطمئن نیستم.");
    if (
      option !== "مطمئن نیستم." &&
      !currentChoices.includes(option) &&
      currentChoices.length >= 3
    ) {
      setError("می‌توانید حداکثر سه نتیجه را انتخاب کنید.");
      return;
    }

    setAnswers((current) => {
      if (option === "مطمئن نیستم.") {
        return { ...current, outcomes: current.outcomes.includes(option) ? [] : [option] };
      }
      const selectedChoices = current.outcomes.filter((choice) => choice !== "مطمئن نیستم.");
      if (selectedChoices.includes(option)) {
        return { ...current, outcomes: selectedChoices.filter((choice) => choice !== option) };
      }
      return { ...current, outcomes: [...selectedChoices, option] };
    });
    setError("");
  }

  function toggleAxis(option: string) {
    setAnswers((current) => {
      if (option === "مطمئن نیستم") {
        return { ...current, axes: current.axes.includes(option) ? [] : [option] };
      }
      const currentChoices = current.axes.filter((choice) => choice !== "مطمئن نیستم");
      return {
        ...current,
        axes: currentChoices.includes(option)
          ? currentChoices.filter((choice) => choice !== option)
          : [...currentChoices, option],
      };
    });
    setError("");
  }

  function validateStep(): boolean {
    switch (step) {
      case 0:
        if (!answers.ideaDescription.trim()) return fail("لطفاً توضیح اولیهٔ ایده را وارد کنید.");
        break;
      case 1:
        if (!answers.education) return fail("لطفاً یک گزینه را انتخاب کنید.");
        if (answers.education === "مورد دیگر" && !answers.educationOther.trim()) {
          return fail("مقطع تحصیلی خود را بنویسید.");
        }
        break;
      case 2:
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(answers.email.trim())) {
          return fail("نشانی ایمیل را به‌درستی وارد کنید.");
        }
        if (!answers.province || !answers.city.trim()) return fail("استان و شهر محل سکونت را وارد کنید.");
        break;
      case 3:
        if (!answers.issueExample.trim()) return fail("لطفاً نمونه‌ای واقعی از مسئله را شرح دهید.");
        break;
      case 4:
        if (!answers.environment) return fail("محیطی را که مسئله را در آن دیده‌اید انتخاب کنید.");
        if (answers.environment === "جای دیگری" && !answers.environmentOther.trim()) {
          return fail("لطفاً محیط موردنظر را مشخص کنید.");
        }
        break;
      case 5:
        if (!answers.visibleChange.trim()) return fail("تغییر قابل‌مشاهدهٔ مورد انتظار را بنویسید.");
        break;
      case 6:
        if (!answers.proposedAction.trim()) return fail("لطفاً اقدام پیشنهادی خود را توضیح دهید.");
        break;
      case 7:
        if (answers.outcomes.length === 0) return fail("حداقل یک نتیجه را انتخاب کنید.");
        if (answers.outcomes.includes("نتیجهٔ دیگری دارد.") && !answers.otherOutcome.trim()) {
          return fail("لطفاً نتیجهٔ مورد انتظار دیگر را توضیح دهید.");
        }
        break;
      case 8:
        if (answers.axes.length === 0) return fail("یک محور رویداد را انتخاب کنید یا «مطمئن نیستم» را بزنید.");
        break;
      case 9:
        if (!answers.title.trim()) return fail("برای ایدهٔ خود عنوانی وارد کنید.");
        break;
      case 10:
        if (answers.audience === "مورد دیگر" && !answers.audienceOther.trim()) {
          return fail("گروه مخاطب را مشخص کنید.");
        }
        break;
      case 11:
        if (!acceptedTerms) return fail("برای ادامه، پذیرش قوانین و شرایط رویداد لازم است.");
        break;
      default:
        return true;
    }
    setError("");
    return true;
  }

  function fail(message: string): false {
    setError(message);
    return false;
  }

  function next() {
    if (validateStep()) setStep((current) => Math.min(current + 1, 12));
  }

  function previous() {
    setError("");
    setStep((current) => Math.max(current - 1, 0));
  }

  function restart() {
    setAnswers({ ...emptyAnswers });
    setAcceptedTerms(false);
    setFinalChoice("");
    setStep(0);
  }

  const progress = step === 12 ? 100 : Math.round((step / 11) * 100);
  const activeTitle = titles[Math.min(step, titles.length - 1)];

  return (
    <main className="intake-shell min-h-screen px-4 py-4 sm:px-7 sm:py-6" dir="rtl">
      <div className="intake-backdrop" aria-hidden="true">
        <div className="home-light-ring" />
        <div className="home-dot-field" />
        <span className="auth-orb auth-orb-green" />
        <span className="auth-orb auth-orb-red" />
      </div>
      <div className="relative mx-auto flex min-h-[calc(100svh-2rem)] max-w-5xl flex-col">
        <header className="flex items-center justify-between gap-4">
          <Link href="/" className="inline-flex items-center gap-2.5" aria-label="بازگشت به جوانه">
            <span className="home-mark" aria-hidden="true">J</span>
            <span className="text-sm font-semibold text-white">جوانه</span>
          </Link>
          <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1.5 text-[0.68rem] text-white/50">
            پیش‌نمایش فرانت‌اند · اطلاعات ذخیره نمی‌شود
          </span>
        </header>

        <div className="my-7 flex flex-1 items-start justify-center sm:my-10">
          <section className="intake-card w-full max-w-3xl overflow-hidden rounded-[1.7rem]">
            <div className="border-b border-white/[0.08] px-5 py-5 sm:px-8 sm:py-6">
              <div className="flex items-center justify-between gap-4">
                <div>
                  <p className="intake-eyebrow text-xs font-medium">
                    {step === 12 ? "پایان پیش‌نمایش" : `گام ${Math.min(step + 1, 12)} از ۱۲`}
                  </p>
                  <h1 className="mt-1.5 text-lg font-semibold text-white sm:text-xl">
                    {step === 12 ? "ثبت پیشنهاد" : activeTitle}
                  </h1>
                </div>
                {step < 12 && (
                  <span className="text-xs tabular-nums text-white/45">{progress}٪</span>
                )}
              </div>
              {step < 12 && (
                <div className="intake-progress mt-4" role="progressbar" aria-valuenow={progress} aria-valuemin={0} aria-valuemax={100} aria-label="میزان پیشرفت فرم">
                  <span style={{ width: `${progress}%` }} />
                </div>
              )}
            </div>

            <div className="px-5 py-6 sm:px-8 sm:py-8">
              {step === 0 && (
                <StepIntro
                  value={answers.ideaDescription}
                  onChange={(value) => update("ideaDescription", value)}
                />
              )}
              {step === 1 && (
                <div>
                  <Question title="آخرین مقطع تحصیلی شما یا مقطعی که در حال حاضر در آن تحصیل می‌کنید چیست؟">
                    <div className="grid gap-2 sm:grid-cols-2">
                      {educationOptions.map((option) => (
                        <ChoiceCard key={option} label={option} radio selected={answers.education === option} onClick={() => update("education", option)} />
                      ))}
                    </div>
                    {answers.education === "مورد دیگر" && (
                      <TextInput label="مقطع تحصیلی" value={answers.educationOther} onChange={(value) => update("educationOther", value)} />
                    )}
                  </Question>
                </div>
              )}
              {step === 2 && (
                <Question title="برای ذخیره و پیگیری پیشنهاد، اطلاعات زیر موردنیاز است." description="شماره موبایل یا نشانی ایمیل شما فقط برای ذخیره و پیگیری پیشنهاد و اطلاع‌رسانی همین رویداد استفاده می‌شود.">
                  <TextInput label="نشانی ایمیل" type="email" dir="ltr" value={answers.email} onChange={(value) => update("email", value)} />
                  <div className="grid gap-4 sm:grid-cols-2">
                    <div>
                      <label htmlFor="intake-province" className="intake-label">استان محل سکونت</label>
                      <select id="intake-province" value={answers.province} onChange={(event) => {
                        update("province", event.target.value);
                        setAnswers((current) => ({ ...current, city: "" }));
                      }} className="intake-input">
                        <option value="">انتخاب استان</option>
                        {provinces.map((province) => <option key={province} value={province}>{province}</option>)}
                      </select>
                    </div>
                    <TextInput label="شهر محل سکونت" value={answers.city} onChange={(value) => update("city", value)} />
                  </div>
                  <p className="text-xs leading-5 text-white/40">در این پیش‌نمایش، اطلاعات فقط در حافظهٔ همین صفحه باقی می‌ماند.</p>
                </Question>
              )}
              {step === 3 && (
                <Question title="به‌نظر شما چه مسئله‌ای را می‌توان بهبود داد؟" description="یک نمونهٔ واقعی را که شخصاً مشاهده یا تجربه کرده‌اید توضیح دهید. نیازی به نگارش تخصصی یا رسمی نیست.">
                  <TextArea label="شرح مسئله" value={answers.issueExample} onChange={(value) => update("issueExample", value)} placeholder="چه اتفاقی می‌افتد و چه کسانی با آن روبه‌رو هستند؟" />
                </Question>
              )}
              {step === 4 && (
                <Question title="این مسئله را بیشتر در چه محیطی مشاهده کرده‌اید؟">
                  <div className="grid gap-2 sm:grid-cols-2">
                    {environmentOptions.map((option) => (
                      <ChoiceCard key={option} label={option} radio selected={answers.environment === option} onClick={() => update("environment", option)} />
                    ))}
                  </div>
                  {answers.environment === "جای دیگری" && (
                    <TextInput label="محیط موردنظر" value={answers.environmentOther} onChange={(value) => update("environmentOther", value)} />
                  )}
                </Question>
              )}
              {step === 5 && (
                <Question title="اگر این مسئله بهبود پیدا کند، مهم‌ترین تغییر قابل‌مشاهده چه خواهد بود؟" description="مهم‌ترین تغییری را بیان کنید که برای افراد قابل‌مشاهده خواهد بود.">
                  <TextArea label="تغییر مورد انتظار" value={answers.visibleChange} onChange={(value) => update("visibleChange", value)} placeholder="پس از بهبود، چه چیزی در زندگی روزمره فرق می‌کند؟" />
                </Question>
              )}
              {step === 6 && (
                <Question title="به‌نظر شما چه فرد، گروه یا مجموعه‌ای باید چه اقدامی را متفاوت انجام دهد تا این مسئله بهبود پیدا کند؟" description="لازم نیست همه جزئیات را بدانید. توضیح دهید چه تغییر یا اقدامی می‌تواند آغاز حل مسئله باشد.">
                  <TextArea label="اقدام پیشنهادی" value={answers.proposedAction} onChange={(value) => update("proposedAction", value)} placeholder="چه کسی می‌تواند چه قدمی بردارد؟" />
                </Question>
              )}
              {step === 7 && (
                <Question title="در صورت اجرای پیشنهاد شما، چه نتایجی انتظار می‌رود؟" description={`می‌توانید بین یک تا سه گزینه انتخاب کنید. ${answers.outcomes.filter((item) => item !== "مطمئن نیستم.").length} از ۳ گزینه انتخاب شده`}>
                  <div className="space-y-2">
                    {outcomeOptions.map((option) => (
                      <ChoiceCard key={option} label={option} selected={answers.outcomes.includes(option)} onClick={() => toggleOutcome(option)} />
                    ))}
                  </div>
                  {answers.outcomes.includes("نتیجهٔ دیگری دارد.") && (
                    <TextArea label="چه نتیجهٔ دیگری مورد انتظار است؟" value={answers.otherOutcome} onChange={(value) => update("otherOutcome", value)} rows={3} />
                  )}
                </Question>
              )}
              {step === 8 && (
                <Question title="به‌نظر شما پیشنهادتان بیشتر با کدام محور رویداد ارتباط دارد؟" description="می‌توانید در صورت ارتباط، بیش از یک محور را انتخاب کنید.">
                  <div className="space-y-2">
                    {axisOptions.map((option) => (
                      <ChoiceCard
                        key={option.title}
                        label={option.title}
                        description={option.description}
                        example={option.example}
                        selected={answers.axes.includes(option.title)}
                        onClick={() => toggleAxis(option.title)}
                      />
                    ))}
                    <ChoiceCard label="به چند محور مربوط است" selected={answers.axes.includes("به چند محور مربوط است")} onClick={() => toggleAxis("به چند محور مربوط است")} />
                    <ChoiceCard label="مطمئن نیستم" selected={answers.axes.includes("مطمئن نیستم")} onClick={() => toggleAxis("مطمئن نیستم")} />
                  </div>
                </Question>
              )}
              {step === 9 && (
                <Question title="چه عنوانی برای ایدهٔ خود انتخاب می‌کنید؟" description="عنوانی کوتاه و روشن انتخاب کنید که مسئله یا راهکار اصلی را بازتاب دهد.">
                  <TextInput label="عنوان ایده" value={answers.title} onChange={(value) => update("title", value)} />
                </Question>
              )}
              {step === 10 && (
                <Question title="در صورت تمایل، اطلاعات کوتاه زیر را درباره زمینه تحصیل یا فعالیت خود تکمیل کنید." description="این اطلاعات برای شناخت بهتر شرکت‌کنندگان و طراحی برنامه‌های بعدی استفاده می‌شود و بر امتیاز اولیه ایده تأثیری ندارد.">
                  <TextInput label="زمینهٔ تحصیلی یا فعالیت (اختیاری)" value={answers.fieldOfStudy} onChange={(value) => update("fieldOfStudy", value)} required={false} />
                  <fieldset>
                    <legend className="intake-label">گروه مخاطب (اختیاری)</legend>
                    <div className="grid gap-2 sm:grid-cols-2">
                      {audienceOptions.map((option) => (
                        <ChoiceCard key={option} label={option} radio selected={answers.audience === option} onClick={() => update("audience", answers.audience === option ? "" : option)} />
                      ))}
                    </div>
                    {answers.audience === "مورد دیگر" && (
                      <TextInput label="گروه مخاطب" value={answers.audienceOther} onChange={(value) => update("audienceOther", value)} />
                    )}
                  </fieldset>
                  <label className="intake-choice flex cursor-pointer items-start gap-3">
                    <input type="checkbox" checked={answers.futureUpdates} onChange={(event) => update("futureUpdates", event.target.checked)} className="intake-native-checkbox mt-1" />
                    <span className="text-sm leading-6">تمایل دارم خبر برنامه‌های آینده را دریافت کنم.</span>
                  </label>
                </Question>
              )}
              {step === 11 && (
                <div className="space-y-5">
                  <div>
                    <h2 className="text-base font-semibold leading-7 text-white">پیشنهاد شما برای ثبت آماده است. پیش از ثبت نهایی می‌توانید پاسخ‌ها را مرور یا ویرایش کنید.</h2>
                    <p className="mt-2 text-sm leading-6 text-white/50">پیش از ثبت، می‌توانید پاسخ‌های خود را یک بار مرور و ویرایش کنید.</p>
                  </div>
                  <ReviewSection title="شرح اولیهٔ ایده" value={answers.ideaDescription} onEdit={() => setStep(0)} />
                  <ReviewSection title="تحصیلات و محل سکونت" value={[answers.education === "مورد دیگر" ? answers.educationOther : answers.education, answers.email, [answers.city, answers.province].filter(Boolean).join("، ")].filter(Boolean).join(" · ")} onEdit={() => setStep(1)} />
                  <ReviewSection title="مسئله و محیط مشاهده" value={[answers.issueExample, answers.environment === "جای دیگری" ? answers.environmentOther : answers.environment].filter(Boolean).join(" · ")} onEdit={() => setStep(3)} />
                  <ReviewSection title="تغییر و اقدام پیشنهادی" value={[answers.visibleChange, answers.proposedAction].filter(Boolean).join("\n")} onEdit={() => setStep(5)} />
                  <ReviewSection title="نتایج و محورهای مرتبط" value={[...answers.outcomes.map((item) => item === "نتیجهٔ دیگری دارد." ? answers.otherOutcome : item), ...answers.axes].filter(Boolean).join("، ")} onEdit={() => setStep(7)} />
                  <ReviewSection title="عنوان و اطلاعات تکمیلی" value={[answers.title, answers.fieldOfStudy, answers.audience === "مورد دیگر" ? answers.audienceOther : answers.audience].filter(Boolean).join(" · ")} onEdit={() => setStep(9)} />
                  <label className="intake-choice flex cursor-pointer items-start gap-3">
                    <input type="checkbox" checked={acceptedTerms} onChange={(event) => {
                      setAcceptedTerms(event.target.checked);
                      setError("");
                    }} className="intake-native-checkbox mt-1" />
                    <span className="text-sm leading-6">قوانین و شرایط رویداد را خواندم و می‌پذیرم. <a href="#event-rules" onClick={(event) => event.stopPropagation()} className="text-emerald-200 underline underline-offset-4">متن قوانین</a></span>
                  </label>
                  <p id="event-rules" className="text-xs leading-5 text-white/40">متن کامل قوانین رویداد پس از اتصال محتوای رسمی در دسترس خواهد بود.</p>
                </div>
              )}
              {step === 12 && (
                <div className="py-4 text-center">
                  <span className="intake-success-mark mx-auto grid size-14 place-items-center rounded-full text-2xl" aria-hidden="true">✓</span>
                  <h2 className="mt-5 text-xl font-semibold text-white">پیشنهاد شما با موفقیت ثبت اولیه شد.</h2>
                  <p className="mx-auto mt-4 max-w-2xl text-sm leading-7 text-white/65">
                    همین اطلاعات برای ثبت پیشنهاد شما در رویداد کافی است؛ بااین‌حال، ایده در وضعیت فعلی هنوز نسبتاً اولیه است و طبیعی است در مقایسه با ایده‌های کامل‌تر، انسجام و احتمال کمتری برای پیشرفت داشته باشد.
                  </p>
                  <p className="mx-auto mt-3 max-w-2xl text-sm leading-7 text-white/55">
                    در صورت تمایل می‌توانید طی دو یا سه روز آینده و در چند نوبت، جزئیات بیشتری به ایده خود اضافه کنید. تکمیل این بخش به‌خودی‌خود امتیاز یا تضمین انتخاب ایجاد نمی‌کند.
                  </p>
                  <p className="intake-demo-note mx-auto mt-5 max-w-xl rounded-xl px-4 py-3 text-xs leading-5">
                    این یک پیش‌نمایش فرانت‌اند است؛ تا زمان اتصال به سامانهٔ ثبت، پاسخ‌ها به سرور ارسال یا ذخیره نشده‌اند.
                  </p>
                  <div className="mx-auto mt-6 grid max-w-md gap-2">
                    {[
                      "ایده‌ام را کامل‌تر می‌کنم",
                      "بعداً ادامه می‌دهم",
                      "یک ایده‌ی دیگر ثبت می‌کنم",
                      "پایان",
                    ].map((choice) => (
                      <button key={choice} type="button" onClick={() => {
                        setFinalChoice(choice);
                        if (choice === "یک ایده‌ی دیگر ثبت می‌کنم") restart();
                      }} className={`intake-final-choice ${finalChoice === choice ? "intake-choice-selected" : ""}`}>
                        {choice}
                      </button>
                    ))}
                  </div>
                  {finalChoice && finalChoice !== "یک ایده‌ی دیگر ثبت می‌کنم" && (
                    <Link href="/" className="home-submit mt-5 inline-flex min-h-11 items-center justify-center rounded-xl px-5 text-sm font-semibold text-[#07120d]">
                      بازگشت به صفحهٔ اصلی
                    </Link>
                  )}
                </div>
              )}

              {error && step < 12 && <p role="alert" className="intake-error mt-5">{error}</p>}

              {step < 12 && (
                <div className="mt-7 flex flex-col-reverse gap-3 border-t border-white/[0.08] pt-5 sm:flex-row sm:items-center sm:justify-between">
                  {step > 0 ? (
                    <button type="button" onClick={previous} className="intake-back-button">مرحلهٔ قبل</button>
                  ) : <span />}
                  <button type="button" onClick={next} className="home-submit inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-[#07120d] transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-200">
                    {step === 11 ? "ثبت اولیهٔ پیشنهاد" : "ادامه"}
                    <span aria-hidden="true">←</span>
                  </button>
                </div>
              )}
            </div>
          </section>
        </div>
        <footer className="flex justify-between gap-4 border-t border-white/10 py-4 text-[0.68rem] text-white/40">
          <span>جوانه · همراه رشد ایده‌ها</span>
          <Link href="/" className="hover:text-white">بازگشت به صفحهٔ اصلی</Link>
        </footer>
      </div>
    </main>
  );
}

function StepIntro({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  return (
    <Question
      title="مایل هستید درباره‌ی چه مشکلی طرح ایده کنید؟ و چه زمینه‌هایی را برای حل آن مستعد تشخیص می‌دهید؟"
      description="مشکلاتی را که تاکنون با آن برخورد داشته‌اید و برای شما مسئله بوده‌اند در نظر بگیرید و راه‌حل‌های احتمالی و راهکارهای پیشنهادی خود را مطرح کنید."
    >
      <TextArea label="شرح اولیهٔ ایده" value={value} onChange={onChange} placeholder="از مسئله‌ای بگویید که دوست دارید برایش راه‌حلی پیدا کنید…" rows={5} />
    </Question>
  );
}

function Question({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-5">
      <div>
        <h2 className="text-base font-semibold leading-8 text-white sm:text-lg">{title}</h2>
        {description && <p className="mt-2 text-sm leading-7 text-white/55">{description}</p>}
      </div>
      {children}
    </div>
  );
}

function TextInput({
  label,
  value,
  onChange,
  type = "text",
  dir,
  required = true,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  type?: string;
  dir?: "rtl" | "ltr";
  required?: boolean;
}) {
  const id = `input-${label.replace(/\s+/g, "-")}`;
  return (
    <div>
      <label htmlFor={id} className="intake-label">{label}</label>
      <input id={id} type={type} dir={dir} required={required} value={value} onChange={(event) => onChange(event.target.value)} className={`intake-input ${dir === "ltr" ? "text-left" : ""}`} />
    </div>
  );
}

function TextArea({
  label,
  value,
  onChange,
  placeholder,
  rows = 5,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  rows?: number;
}) {
  const id = `textarea-${label.replace(/\s+/g, "-")}`;
  return (
    <div>
      <label htmlFor={id} className="intake-label">{label}</label>
      <textarea id={id} required value={value} onChange={(event) => onChange(event.target.value)} placeholder={placeholder} rows={rows} className="intake-input min-h-32 resize-y leading-7 placeholder:text-white/30" />
    </div>
  );
}

function ReviewSection({
  title,
  value,
  onEdit,
}: {
  title: string;
  value: string;
  onEdit: () => void;
}) {
  return (
    <section className="intake-review rounded-xl p-4">
      <div className="flex items-start justify-between gap-4">
        <h3 className="text-sm font-medium text-white/85">{title}</h3>
        <button type="button" onClick={onEdit} className="shrink-0 text-xs text-emerald-200 underline underline-offset-4">ویرایش</button>
      </div>
      <p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-white/55">{value || "—"}</p>
    </section>
  );
}
