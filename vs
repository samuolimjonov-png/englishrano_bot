import asyncio
import json
import os
import re
import logging
from datetime import datetime

from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import CommandStart, CommandObject
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import (Message, CallbackQuery, InlineKeyboardMarkup,
                           InlineKeyboardButton)

# ===================== SOZLAMALAR =====================
TOKEN = os.getenv("BOT_TOKEN") or "8975938181:AAGPFQ1wTcfaEyA6BH4eV2q3jhLnNjdfSrY"   # @BotFather dan olingan token
ADMIN_PASSWORD = "9091"
DB_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data.json")

DAYS = {"juft": "Seshanba-Payshanba-Shanba", "toq": "Dushanba-Chorshanba-Juma"}

# ===================== MA'LUMOTLAR BAZASI (JSON) =====================
def load():
    if os.path.exists(DB_FILE):
        with open(DB_FILE, encoding="utf-8") as f:
            return json.load(f)
    return {"groups": {}, "students": {}, "tests": [], "sessions": {}, "counter": 0}

db = load()

def save():
    with open(DB_FILE, "w", encoding="utf-8") as f:
        json.dump(db, f, ensure_ascii=False, indent=2)

def new_id():
    db["counter"] += 1
    return str(db["counter"])

# ===================== YORDAMCHI FUNKSIYALAR =====================
def month_key():
    return datetime.now().strftime("%Y-%m")

def today():
    return datetime.now().strftime("%Y-%m-%d")

def fmt_date(d):
    return f"{d[8:10]}.{d[5:7]}"

def fmt_group(gid):
    g = db["groups"][gid]
    return f"{g['time']} {'Juft' if g['days'] == 'juft' else 'Toq'}"

def sorted_groups(days=None):
    ids = [g for g, v in db["groups"].items() if days is None or v["days"] == days]
    return sorted(ids, key=lambda g: (db["groups"][g]["days"], db["groups"][g]["time"]))

def group_students(gid):
    res = [sid for sid, s in db["students"].items() if s["group"] == gid]
    return sorted(res, key=lambda x: sname(x).lower())

def sname(sid):
    return db["students"][sid]["name"]

def is_paid(s):
    return month_key() in s["payments"]

def month_absences(s):
    return sorted(d for d in s["absences"] if d.startswith(month_key()))

def rating_list():
    return sorted(db["students"], key=lambda x: (-db["students"][x]["ball"], sname(x).lower()))

def label(sid):
    s = db["students"][sid]
    return f"{s['name']} • {fmt_group(s['group'])}"

def parse_time(t):
    m = re.fullmatch(r"(\d{1,2})[:.](\d{2})", t.strip())
    if not m:
        return None
    h, mi = int(m[1]), int(m[2])
    if mi > 59 or h < 8 or h > 20 or (h == 20 and mi > 0):
        return None
    return f"{h:02d}:{mi:02d}"

def digits(t):
    return "".join(ch for ch in t if ch.isdigit())

def group_exists(days, time, skip=None):
    return any(v["days"] == days and v["time"] == time and g != skip
               for g, v in db["groups"].items())

def notify_ids(s):
    return set(s.get("parents", []) + s.get("tg_ids", []))

def kb(*rows):
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=t, callback_data=d) for t, d in row] for row in rows])

def student_text(sid, admin=False):
    s = db["students"][sid]
    g = db["groups"][s["group"]]
    rank = rating_list()
    ab = month_absences(s)
    pays = s["payments"]
    lines = [
        f"👤 {s['name']}",
        f"📅 Guruh: {fmt_group(s['group'])} ({DAYS[g['days']]})",
        f"⭐ Bal: {s['ball']}",
        f"🏆 Reyting: {rank.index(sid) + 1}-o'rin ({len(rank)} ta o'quvchidan)",
        f"💳 {month_key()} oyi uchun to'lov: " + ("✅ to'langan" if is_paid(s) else "❌ to'lanmagan"),
        "🧾 To'lov sanalari: " + (", ".join(f"{m}: {d}" for m, d in sorted(pays.items())) if pays else "yo'q"),
        f"🚫 Shu oy qoldirgan kunlar ({len(ab)}): " + (", ".join(fmt_date(d) for d in ab) if ab else "yo'q"),
    ]
    if admin:
        lines.insert(1, f"📞 Tel: {s['phone']}")
        lines.append(f"👨‍👩‍👦 Ulangan ota-ona: {len(s['parents'])} ta")
    return "\n".join(lines)

async def show(target, text, markup=None):
    if isinstance(target, CallbackQuery):
        try:
            await target.message.edit_text(text, reply_markup=markup)
        except Exception:
            await target.message.answer(text, reply_markup=markup)
        try:
            await target.answer()
        except Exception:
            pass
    else:
        await target.answer(text, reply_markup=markup)

def is_admin(uid):
    return db["sessions"].get(str(uid), {}).get("role") == "admin"

# ===================== HOLATLAR =====================
class Reg(StatesGroup):
    name = State()
    days = State()
    time = State()
    phone = State()
    confirm = State()

class Login(StatesGroup):
    admin = State()
    student = State()

class Adm(StatesGroup):
    search = State()
    new_time = State()
    edit_time = State()
    test_text = State()

main_r = Router()
admin_r = Router()
admin_r.message.filter(lambda m: is_admin(m.from_user.id))
admin_r.callback_query.filter(lambda c: is_admin(c.from_user.id))

# ===================== BOSHLANISH / ROL TANLASH =====================
async def role_screen(target):
    await show(target, "Assalomu alaykum! Kim sifatida kirasiz?",
               kb([("👨‍🏫 Admin", "role:admin"), ("🎓 Student", "role:student")]))

@main_r.message(CommandStart())
async def cmd_start(m: Message, command: CommandObject, state: FSMContext):
    await state.clear()
    arg = command.args or ""
    if arg.startswith("p"):                      # ota-ona havolasi
        sid = arg[1:]
        if sid in db["students"]:
            s = db["students"][sid]
            if m.from_user.id not in s["parents"]:
                s["parents"].append(m.from_user.id)
                save()
            await m.answer(f"✅ Siz {s['name']} ning ota-onasi sifatida ulandingiz.\n"
                           f"Farzandingiz darsga kelmasa, shu yerga xabar keladi.")
            return
    await role_screen(m)

@main_r.callback_query(F.data == "start")
async def cb_start(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    await role_screen(cb)

@main_r.callback_query(F.data == "logout")
async def cb_logout(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    db["sessions"].pop(str(cb.from_user.id), None)
    save()
    await role_screen(cb)

# ===================== ADMIN KIRISH =====================
@main_r.callback_query(F.data == "role:admin")
async def role_admin(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Login.admin)
    await show(cb, "🔑 Admin parolini kiriting:", kb([("⬅️ Back", "start")]))

@main_r.message(Login.admin)
async def admin_login(m: Message, state: FSMContext):
    try:
        await m.delete()
    except Exception:
        pass
    if (m.text or "").strip() == ADMIN_PASSWORD:
        db["sessions"][str(m.from_user.id)] = {"role": "admin"}
        save()
        await state.clear()
        await admin_menu(m)
    else:
        await m.answer("❌ Parol noto'g'ri. Qaytadan kiriting:", reply_markup=kb([("⬅️ Back", "start")]))

# ===================== STUDENT: RO'YXATDAN O'TISH =====================
@main_r.callback_query(F.data == "role:student")
async def role_student(cb: CallbackQuery, state: FSMContext):
    await state.clear()
    await show(cb, "🎓 Student bo'limi", kb(
        [("📝 Ro'yxatdan o'tish", "reg:start")],
        [("🔑 Kirish", "login:student")],
        [("⬅️ Back", "start")]))

@main_r.callback_query(F.data == "reg:start")
async def reg_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Reg.name)
    await show(cb, "✍️ Ism va familyangizni yozing\n(masalan: Olimjonov Sardor)",
               kb([("⬅️ Back", "role:student")]))

@main_r.message(Reg.name)
async def reg_name(m: Message, state: FSMContext):
    name = (m.text or "").strip()
    if len(name.split()) < 2:
        await m.answer("Iltimos, ism va familyani birga yozing (masalan: Olimjonov Sardor)")
        return
    await state.update_data(name=name)
    await state.set_state(Reg.days)
    await m.answer(
        "📅 Qaysi kunlari kelasiz?\n\n"
        "Seshanba, Payshanba, Shanba kuni bo'lsa — JUFT ni bosing.\n"
        "Dushanba, Chorshanba, Juma kuni bo'lsa — TOQ ni bosing.",
        reply_markup=kb([("Juft", "rd:juft"), ("Toq", "rd:toq")]))

@main_r.callback_query(F.data.startswith("rd:"))
async def reg_days(cb: CallbackQuery, state: FSMContext):
    days = cb.data[3:]
    groups = sorted_groups(days)
    if not groups:
        await cb.answer("Bu kunlar uchun guruh yo'q. Ustozga murojaat qiling.", show_alert=True)
        return
    await state.set_state(Reg.time)
    rows = [[(db["groups"][g]["time"], f"rt:{g}")] for g in groups]
    await show(cb, "🕒 Dars vaqtini tanlang:", kb(*rows))

@main_r.callback_query(F.data.startswith("rt:"))
async def reg_time(cb: CallbackQuery, state: FSMContext):
    await state.update_data(gid=cb.data[3:])
    await state.set_state(Reg.phone)
    await show(cb, "📞 Parol sifatida telefon raqamingizni yozing\n(masalan: 901234567). Keyin shu bilan kirasiz.")

@main_r.message(Reg.phone)
async def reg_phone(m: Message, state: FSMContext):
    ph = digits(m.text or "")
    if len(ph) < 9:
        await m.answer("Telefon raqam noto'g'ri. Qaytadan yozing:")
        return
    if any(digits(s["phone"])[-9:] == ph[-9:] for s in db["students"].values()):
        await m.answer("Bu raqam allaqachon ro'yxatdan o'tgan. Boshqa raqam yozing:")
        return
    await state.update_data(phone=ph)
    d = await state.get_data()
    await state.set_state(Reg.confirm)
    await m.answer(
        f"Ma'lumotlarni tekshiring:\n\n👤 {d['name']}\n📅 Guruh: {fmt_group(d['gid'])}\n📞 Parol: {ph}",
        reply_markup=kb([("💾 Saqlash", "rs:yes"), ("🚫 Saqlamaslik", "rs:no")]))

@main_r.callback_query(F.data.startswith("rs:"))
async def reg_confirm(cb: CallbackQuery, state: FSMContext):
    d = await state.get_data()
    await state.clear()
    if cb.data == "rs:yes" and d.get("name"):
        sid = new_id()
        db["students"][sid] = {"name": d["name"], "phone": d["phone"], "group": d["gid"],
                               "ball": 0, "tg_ids": [], "parents": [],
                               "absences": [], "payments": {}}
        save()
        me = await cb.bot.get_me()
        await show(cb, "✅ Saqlandi!\n\nOta-onangiz farzandining darsga kelmagani haqida xabar olishi uchun "
                       f"ularga shu havolani yuboring:\nhttps://t.me/{me.username}?start=p{sid}")
    else:
        await show(cb, "🚫 Saqlanmadi.")
    await role_screen(cb.message)

# ===================== STUDENT: KIRISH =====================
@main_r.callback_query(F.data == "login:student")
async def login_student(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Login.student)
    await show(cb, "🔑 Parolni kiriting (telefon raqamingiz):", kb([("⬅️ Back", "role:student")]))

@main_r.message(Login.student)
async def student_login(m: Message, state: FSMContext):
    try:
        await m.delete()
    except Exception:
        pass
    ph = digits(m.text or "")
    found = next((sid for sid, s in db["students"].items()
                  if len(ph) >= 9 and digits(s["phone"])[-9:] == ph[-9:]), None)
    if not found:
        await m.answer("❌ Parol noto'g'ri. Qaytadan kiriting:", reply_markup=kb([("⬅️ Back", "role:student")]))
        return
    s = db["students"][found]
    if m.from_user.id not in s["tg_ids"]:
        s["tg_ids"].append(m.from_user.id)
    db["sessions"][str(m.from_user.id)] = {"role": "student", "sid": found}
    save()
    await state.clear()
    await m.answer(student_text(found), reply_markup=student_kb())

def student_kb():
    return kb([("🧪 Testlar", "st:tests"), ("🔄 Yangilash", "st:me")], [("⬅️ Chiqish", "logout")])

def cur_student(uid):
    s = db["sessions"].get(str(uid))
    if s and s.get("role") == "student" and s["sid"] in db["students"]:
        return s["sid"]
    return None

@main_r.callback_query(F.data == "st:me")
async def st_me(cb: CallbackQuery):
    sid = cur_student(cb.from_user.id)
    if not sid:
        return await role_screen(cb)
    await show(cb, student_text(sid), student_kb())

@main_r.callback_query(F.data == "st:tests")
async def st_tests(cb: CallbackQuery):
    sid = cur_student(cb.from_user.id)
    if not sid:
        return await role_screen(cb)
    gid = db["students"][sid]["group"]
    tests = [t for t in db["tests"] if t["gid"] == gid][-10:]
    text = "🧪 Testlar:\n\n" + "\n\n".join(f"📌 {t['date']}\n{t['text']}" for t in tests) if tests \
        else "🧪 Hozircha test yo'q."
    await show(cb, text, kb([("⬅️ Back", "st:me")]))

# ===================== ADMIN: ASOSIY MENYU =====================
async def admin_menu(target):
    total = len(db["students"])
    unpaid = sum(1 for s in db["students"].values() if not is_paid(s))
    await show(target,
               f"👨‍🏫 Admin paneli\nJami o'quvchilar: {total}\nShu oy to'lamaganlar: {unpaid}",
               kb([("💸 To'lovsizlar", "a:u"), ("💰 To'lovlilar", "a:p")],
                  [("🏆 O'quvchilar reytingi", "a:r"), ("📋 Yo'qlama", "a:att")],
                  [("⭐ Bal qo'shish", "a:bal"), ("🧪 Test", "a:test")],
                  [("✏️ Edits", "a:edit")],
                  [("⬅️ Chiqish", "logout")]))

@admin_r.callback_query(F.data == "a:menu")
async def a_menu(cb: CallbackQuery, state: FSMContext):
    await state.set_state(None)
    await admin_menu(cb)

# ----- To'lovsizlar / To'lovlilar / Reyting -----
def scope(ctx):
    allids = list(db["students"])
    if ctx == "u":
        return [x for x in allids if not is_paid(db["students"][x])]
    if ctx == "p":
        return [x for x in allids if is_paid(db["students"][x])]
    return allids

async def show_list(target, ctx):
    ids = sorted(scope(ctx), key=lambda x: sname(x).lower())
    title = {"u": "💸 Shu oy to'lamaganlar", "p": "💰 Shu oy to'laganlar"}[ctx]
    rows = [[(label(x), f"s:{x}:{ctx}")] for x in ids[:50]]
    rows.append([("🔍 Qidirish", f"q:{ctx}")])
    rows.append([("⬅️ Back", "a:menu")])
    await show(target, f"{title} ({len(ids)} ta)" + ("" if ids else "\n\nRo'yxat bo'sh."), kb(*rows))

async def show_rating(target):
    rank = rating_list()
    text = "🏆 O'quvchilar reytingi\n\n" + ("\n".join(
        f"{i}. {sname(x)} — {db['students'][x]['ball']} bal ({fmt_group(db['students'][x]['group'])})"
        for i, x in enumerate(rank[:50], 1)) or "Hozircha o'quvchi yo'q.")
    await show(target, text, kb([("🔍 Qidirish", "q:r")], [("⬅️ Back", "a:menu")]))

@admin_r.callback_query(F.data.in_({"a:u", "a:p"}))
async def a_lists(cb: CallbackQuery, state: FSMContext):
    await state.set_state(None)
    await show_list(cb, cb.data[2])

@admin_r.callback_query(F.data == "a:r")
async def a_rating(cb: CallbackQuery):
    await show_rating(cb)

# ----- Qidiruv -----
@admin_r.callback_query(F.data.startswith("q:"))
async def q_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Adm.search)
    await state.update_data(sctx=cb.data[2:])
    await cb.message.answer("🔍 Ism yoki familya kiriting (masalan: olimjonov):")
    await cb.answer()

@admin_r.message(Adm.search)
async def q_do(m: Message, state: FSMContext):
    ctx = (await state.get_data()).get("sctx", "r")
    await state.set_state(None)
    q = (m.text or "").strip().lower()
    res = sorted((x for x in scope(ctx) if q in sname(x).lower()), key=lambda x: sname(x).lower())
    rows = [[(label(x), f"s:{x}:{ctx}")] for x in res[:40]]
    rows.append([("🔍 Qayta qidirish", f"q:{ctx}")])
    rows.append([("⬅️ Back", f"back:{ctx}")])
    await m.answer(f"Natija: {len(res)} ta" if res else "Hech narsa topilmadi.", reply_markup=kb(*rows))

# ----- O'quvchi kartasi (admin) -----
def admin_card_kb(sid, ctx):
    paid = is_paid(db["students"][sid])
    return kb(
        [("↩️ To'lovni bekor qilish" if paid else "💳 Shu oy to'lov qildi", f"pay:{sid}:{ctx}")],
        [("-10", f"bal:{sid}:-10:{ctx}"), ("-5", f"bal:{sid}:-5:{ctx}"),
         ("+5", f"bal:{sid}:+5:{ctx}"), ("+10", f"bal:{sid}:+10:{ctx}")],
        [("⬅️ Back", f"back:{ctx}")])

@admin_r.callback_query(F.data.startswith("s:"))
async def a_card(cb: CallbackQuery):
    _, sid, ctx = cb.data.split(":")
    if sid not in db["students"]:
        return await cb.answer("O'quvchi topilmadi", show_alert=True)
    await show(cb, student_text(sid, admin=True), admin_card_kb(sid, ctx))

@admin_r.callback_query(F.data.startswith("pay:"))
async def a_pay(cb: CallbackQuery):
    _, sid, ctx = cb.data.split(":")
    s = db["students"][sid]
    if is_paid(s):
        s["payments"].pop(month_key(), None)
    else:
        s["payments"][month_key()] = today()
    save()
    await show(cb, student_text(sid, admin=True), admin_card_kb(sid, ctx))

@admin_r.callback_query(F.data.startswith("bal:"))
async def a_bal(cb: CallbackQuery):
    _, sid, delta, ctx = cb.data.split(":")
    db["students"][sid]["ball"] += int(delta)
    save()
    await show(cb, student_text(sid, admin=True), admin_card_kb(sid, ctx))

# ----- Orqaga qaytish -----
@admin_r.callback_query(F.data.startswith("back:"))
async def a_back(cb: CallbackQuery, state: FSMContext):
    ctx = cb.data[5:]
    if ctx in ("u", "p"):
        await show_list(cb, ctx)
    elif ctx == "r":
        await show_rating(cb)
    elif ctx[0] == "g" and ctx[1:] in db["groups"]:
        await show_group_students(cb, ctx[1:])
    elif ctx[0] == "a" and ctx[1:] in db["groups"]:
        await render_att(cb, state, ctx[1:])
    else:
        await admin_menu(cb)

# ----- Bal qo'shish -----
@admin_r.callback_query(F.data == "a:bal")
async def a_bal_menu(cb: CallbackQuery):
    groups = sorted_groups()
    if not groups:
        return await cb.answer("Guruhlar yo'q. Avval Edits orqali guruh qo'shing.", show_alert=True)
    rows = [[(fmt_group(g), f"gb:{g}")] for g in groups]
    rows.append([("⬅️ Back", "a:menu")])
    await show(cb, "⭐ Bal qo'shish: guruhni tanlang (juft/toq va soat):", kb(*rows))

async def show_group_students(target, gid):
    rows = [[(sname(x) + f" ({db['students'][x]['ball']})", f"s:{x}:g{gid}")] for x in group_students(gid)]
    rows.append([("⬅️ Back", "a:bal")])
    await show(target, f"⭐ {fmt_group(gid)} guruhi. O'quvchini tanlang:", kb(*rows))

@admin_r.callback_query(F.data.startswith("gb:"))
async def a_gb(cb: CallbackQuery):
    await show_group_students(cb, cb.data[3:])

# ===================== YO'QLAMA =====================
@admin_r.callback_query(F.data == "a:att")
async def a_att(cb: CallbackQuery):
    groups = sorted_groups()
    if not groups:
        return await cb.answer("Guruhlar yo'q. Avval Edits orqali guruh qo'shing.", show_alert=True)
    rows = [[(fmt_group(g), f"att:{g}")] for g in groups]
    rows.append([("⬅️ Back", "a:menu")])
    await show(cb, "📋 Yo'qlama: guruhni tanlang (soat va juft/toq):", kb(*rows))

async def render_att(target, state, gid):
    d = await state.get_data()
    absent = d.get("absent", []) if d.get("att_gid") == gid else []
    await state.update_data(att_gid=gid, absent=absent)
    rows = []
    for sid in group_students(gid):
        rows.append([(f"👤 {sname(sid)}", f"s:{sid}:a{gid}"),
                     ("❌" if sid in absent else "✅", f"atm:{sid}:{gid}")])
    rows.append([("💾 Saqlash va xabar yuborish", f"ats:{gid}")])
    rows.append([("⬅️ Back", "a:att")])
    await show(target, f"📋 {fmt_group(gid)} — {today()}\n✅ keldi | ❌ kelmadi (belgini bosib o'zgartiring)\n"
                       f"Ism ustiga bossangiz o'quvchi ma'lumoti chiqadi.", kb(*rows))

@admin_r.callback_query(F.data.startswith("att:"))
async def a_att_open(cb: CallbackQuery, state: FSMContext):
    await state.update_data(att_gid=None, absent=[])
    await render_att(cb, state, cb.data[4:])

@admin_r.callback_query(F.data.startswith("atm:"))
async def a_att_toggle(cb: CallbackQuery, state: FSMContext):
    _, sid, gid = cb.data.split(":")
    d = await state.get_data()
    absent = d.get("absent", []) if d.get("att_gid") == gid else []
    if sid in absent:
        absent.remove(sid)
    else:
        absent.append(sid)
    await state.update_data(att_gid=gid, absent=absent)
    await render_att(cb, state, gid)

@admin_r.callback_query(F.data.startswith("ats:"))
async def a_att_save(cb: CallbackQuery, state: FSMContext):
    gid = cb.data[4:]
    d = await state.get_data()
    absent = d.get("absent", []) if d.get("att_gid") == gid else []
    sent, no_parent = 0, 0
    for sid in absent:
        s = db["students"][sid]
        if today() in s["absences"]:
            continue                      # bugun allaqachon belgilangan
        s["absences"].append(today())
        if not s["parents"]:
            no_parent += 1
        text = f"❗️ {s['name']} bugun ({fmt_date(today())}) {fmt_group(gid)} guruhidagi ingliz tili darsiga kelmadi."
        for uid in notify_ids(s):
            try:
                await cb.bot.send_message(uid, text)
                sent += 1
            except Exception:
                pass
    save()
    await state.update_data(att_gid=None, absent=[])
    await show(cb, f"✅ Yo'qlama saqlandi.\nKelmaganlar: {len(absent)} ta\nYuborilgan xabarlar: {sent} ta"
                   + (f"\n⚠️ Ota-onasi ulanmagan o'quvchilar: {no_parent} ta" if no_parent else ""),
               kb([("⬅️ Back", "a:att")]))

# ===================== TEST =====================
@admin_r.callback_query(F.data == "a:test")
async def a_test(cb: CallbackQuery):
    await show(cb, "🧪 Test bo'limi", kb([("➕ Test qo'shish", "t:add")],
                                         [("📋 Testlar ro'yxati", "t:list")],
                                         [("⬅️ Back", "a:menu")]))

@admin_r.callback_query(F.data == "t:add")
async def t_add(cb: CallbackQuery):
    groups = sorted_groups()
    if not groups:
        return await cb.answer("Guruhlar yo'q.", show_alert=True)
    rows = [[(fmt_group(g), f"tg:{g}")] for g in groups]
    rows.append([("⬅️ Back", "a:test")])
    await show(cb, "Test qaysi guruh uchun?", kb(*rows))

@admin_r.callback_query(F.data.startswith("tg:"))
async def t_group(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Adm.test_text)
    await state.update_data(tgid=cb.data[3:])
    await show(cb, "📝 Test matnini yoki havolasini yuboring:")

@admin_r.message(Adm.test_text)
async def t_text(m: Message, state: FSMContext):
    gid = (await state.get_data())["tgid"]
    await state.set_state(None)
    db["tests"].append({"gid": gid, "text": m.text, "date": today()})
    save()
    sent = 0
    for sid in group_students(gid):
        for uid in db["students"][sid]["tg_ids"]:
            try:
                await m.bot.send_message(uid, f"🧪 Yangi test ({fmt_group(gid)}):\n\n{m.text}")
                sent += 1
            except Exception:
                pass
    await m.answer(f"✅ Test saqlandi va {sent} ta o'quvchiga yuborildi.",
                   reply_markup=kb([("⬅️ Back", "a:test")]))

@admin_r.callback_query(F.data == "t:list")
async def t_list(cb: CallbackQuery):
    tests = db["tests"][-15:]
    text = "📋 Oxirgi testlar:\n\n" + "\n\n".join(
        f"📌 {t['date']} • {fmt_group(t['gid']) if t['gid'] in db['groups'] else '?'}\n{t['text']}"
        for t in tests) if tests else "Hozircha test yo'q."
    await show(cb, text, kb([("⬅️ Back", "a:test")]))

# ===================== EDITS (faqat admin) =====================
def edits_kb():
    return kb([("➕ Guruh qo'shish", "e:add")],
              [("✏️ Guruh tahrirlash (soat/kun)", "e:edit")],
              [("🔁 O'quvchini boshqa guruhga o'tkazish", "e:tr")],
              [("🗑 Guruhni o'chirish", "e:del")],
              [("⬅️ Back", "a:menu")])

@admin_r.callback_query(F.data == "a:edit")
async def a_edit(cb: CallbackQuery, state: FSMContext):
    await state.set_state(None)
    await show(cb, "✏️ Edits bo'limi", edits_kb())

# ----- guruh qo'shish -----
@admin_r.callback_query(F.data == "e:add")
async def e_add(cb: CallbackQuery):
    await show(cb, "Yangi guruh: kunlarni tanlang\n\nJuft = Seshanba, Payshanba, Shanba\nToq = Dushanba, Chorshanba, Juma",
               kb([("Juft", "ea:juft"), ("Toq", "ea:toq")], [("⬅️ Back", "a:edit")]))

@admin_r.callback_query(F.data.startswith("ea:"))
async def e_add_days(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Adm.new_time)
    await state.update_data(days=cb.data[3:])
    await show(cb, "🕒 Dars vaqtini yozing (08:00 dan 20:00 gacha), masalan: 15:30")

@admin_r.message(Adm.new_time)
async def e_add_time(m: Message, state: FSMContext):
    t = parse_time(m.text or "")
    days = (await state.get_data())["days"]
    if not t:
        return await m.answer("Vaqt noto'g'ri. 08:00 dan 20:00 gacha, masalan 15:30:")
    if group_exists(days, t):
        return await m.answer("Bunday guruh allaqachon bor. Boshqa vaqt yozing:")
    gid = new_id()
    db["groups"][gid] = {"days": days, "time": t}
    save()
    await state.set_state(None)
    await m.answer(f"✅ Guruh qo'shildi: {fmt_group(gid)}", reply_markup=edits_kb())

# ----- guruh tahrirlash -----
@admin_r.callback_query(F.data == "e:edit")
async def e_edit(cb: CallbackQuery):
    groups = sorted_groups()
    rows = [[(fmt_group(g), f"ee:{g}")] for g in groups]
    rows.append([("⬅️ Back", "a:edit")])
    await show(cb, "Qaysi guruhni tahrirlaymiz?" if groups else "Guruhlar yo'q.", kb(*rows))

@admin_r.callback_query(F.data.startswith("ee:"))
async def e_edit_one(cb: CallbackQuery):
    gid = cb.data[3:]
    await show(cb, f"✏️ Guruh: {fmt_group(gid)}", kb(
        [("🕒 Soatni o'zgartirish", f"eet:{gid}")],
        [("🔄 Juft ↔ Toq", f"eed:{gid}")],
        [("⬅️ Back", "e:edit")]))

@admin_r.callback_query(F.data.startswith("eet:"))
async def e_edit_time(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Adm.edit_time)
    await state.update_data(egid=cb.data[4:])
    await show(cb, "🕒 Yangi vaqtni yozing (masalan: 16:00):")

@admin_r.message(Adm.edit_time)
async def e_edit_time_do(m: Message, state: FSMContext):
    gid = (await state.get_data())["egid"]
    t = parse_time(m.text or "")
    if not t:
        return await m.answer("Vaqt noto'g'ri. 08:00 dan 20:00 gacha, masalan 16:00:")
    if group_exists(db["groups"][gid]["days"], t, skip=gid):
        return await m.answer("Bunday guruh allaqachon bor. Boshqa vaqt yozing:")
    db["groups"][gid]["time"] = t
    save()
    await state.set_state(None)
    await m.answer(f"✅ Yangilandi: {fmt_group(gid)}", reply_markup=edits_kb())

@admin_r.callback_query(F.data.startswith("eed:"))
async def e_edit_days(cb: CallbackQuery):
    gid = cb.data[4:]
    g = db["groups"][gid]
    new = "toq" if g["days"] == "juft" else "juft"
    if group_exists(new, g["time"], skip=gid):
        return await cb.answer("Bu vaqtda bunday guruh allaqachon bor.", show_alert=True)
    g["days"] = new
    save()
    await show(cb, f"✅ Yangilandi: {fmt_group(gid)}", edits_kb())

# ----- o'quvchini ko'chirish (transfer) -----
@admin_r.callback_query(F.data == "e:tr")
async def e_tr(cb: CallbackQuery):
    rows = [[(f"{fmt_group(g)} ({len(group_students(g))} ta)", f"et1:{g}")] for g in sorted_groups()]
    rows.append([("⬅️ Back", "a:edit")])
    await show(cb, "🔁 Qaysi guruhdan o'tkazamiz?", kb(*rows))

@admin_r.callback_query(F.data.startswith("et1:"))
async def e_tr1(cb: CallbackQuery):
    gid = cb.data[4:]
    rows = [[(sname(x), f"et2:{x}")] for x in group_students(gid)]
    rows.append([("⬅️ Back", "e:tr")])
    await show(cb, f"{fmt_group(gid)} — o'quvchini tanlang:", kb(*rows))

@admin_r.callback_query(F.data.startswith("et2:"))
async def e_tr2(cb: CallbackQuery):
    sid = cb.data[4:]
    cur = db["students"][sid]["group"]
    rows = [[(fmt_group(g), f"et3:{sid}:{g}")] for g in sorted_groups() if g != cur]
    rows.append([("⬅️ Back", "e:tr")])
    await show(cb, f"{sname(sid)} qaysi guruhga o'tadi?", kb(*rows))

@admin_r.callback_query(F.data.startswith("et3:"))
async def e_tr3(cb: CallbackQuery):
    _, sid, gid = cb.data.split(":")
    s = db["students"][sid]
    old = fmt_group(s["group"])
    s["group"] = gid
    save()
    for uid in notify_ids(s):
        try:
            await cb.bot.send_message(uid, f"🔁 {s['name']} {old} guruhidan {fmt_group(gid)} guruhiga o'tkazildi.")
        except Exception:
            pass
    await show(cb, f"✅ {s['name']}: {old} → {fmt_group(gid)}", edits_kb())

# ----- guruhni o'chirish -----
@admin_r.callback_query(F.data == "e:del")
async def e_del(cb: CallbackQuery):
    rows = [[(f"{fmt_group(g)} ({len(group_students(g))} ta)", f"ed:{g}")] for g in sorted_groups()]
    rows.append([("⬅️ Back", "a:edit")])
    await show(cb, "🗑 Qaysi guruh o'chirilsin? (faqat bo'sh guruh)", kb(*rows))

@admin_r.callback_query(F.data.startswith("ed:"))
async def e_del_do(cb: CallbackQuery):
    gid = cb.data[3:]
    if group_students(gid):
        return await cb.answer("Guruhda o'quvchilar bor. Avval ularni boshqa guruhga o'tkazing.", show_alert=True)
    name = fmt_group(gid)
    db["groups"].pop(gid, None)
    save()
    await show(cb, f"🗑 O'chirildi: {name}", edits_kb())

# ===================== ISHGA TUSHIRISH =====================
async def main():
    logging.basicConfig(level=logging.INFO)
    bot = Bot(TOKEN)
    dp = Dispatcher(storage=MemoryStorage())
    dp.include_router(main_r)
    dp.include_router(admin_r)
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
