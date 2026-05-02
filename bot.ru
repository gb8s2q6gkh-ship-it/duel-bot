import os
import sqlite3
from datetime import datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, MessageHandler, filters, ContextTypes

TOKEN = os.getenv("TOKEN")
ADMIN_ID = int(os.getenv("ADMIN_ID", "0"))

duels = {}

# ========== БАЗА ДАННЫХ ==========
def init_db():
    conn = sqlite3.connect('duel_stats.db')
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS stats
                 (chat_id INTEGER, user_id INTEGER, wins INTEGER, total_duels INTEGER,
                 PRIMARY KEY (chat_id, user_id))''')
    conn.commit()
    conn.close()

def update_stats(chat_id, user_id, is_winner):
    conn = sqlite3.connect('duel_stats.db')
    c = conn.cursor()
    c.execute("SELECT wins, total_duels FROM stats WHERE chat_id = ? AND user_id = ?", (chat_id, user_id))
    result = c.fetchone()
    if result:
        wins, total = result
        if is_winner:
            wins += 1
        total += 1
        c.execute("UPDATE stats SET wins = ?, total_duels = ? WHERE chat_id = ? AND user_id = ?",
                  (wins, total, chat_id, user_id))
    else:
        wins = 1 if is_winner else 0
        c.execute("INSERT INTO stats (chat_id, user_id, wins, total_duels) VALUES (?, ?, ?, ?)",
                  (chat_id, user_id, wins, 1))
    conn.commit()
    conn.close()

def get_stats(chat_id, user_id):
    conn = sqlite3.connect('duel_stats.db')
    c = conn.cursor()
    c.execute("SELECT wins, total_duels FROM stats WHERE chat_id = ? AND user_id = ?", (chat_id, user_id))
    result = c.fetchone()
    conn.close()
    return result if result else (0, 0)

def get_all_stats(chat_id):
    conn = sqlite3.connect('duel_stats.db')
    c = conn.cursor()
    c.execute("SELECT user_id, wins, total_duels FROM stats WHERE chat_id = ? ORDER BY wins DESC", (chat_id,))
    result = c.fetchall()
    conn.close()
    return result

def clear_stats(chat_id):
    conn = sqlite3.connect('duel_stats.db')
    c = conn.cursor()
    c.execute("DELETE FROM stats WHERE chat_id = ?", (chat_id,))
    conn.commit()
    conn.close()

# ========== КОМАНДА /duel ==========
async def duel_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    user1 = update.effective_user
    user1_id = user1.id
    user1_name = user1.first_name

    if not update.message.reply_to_message:
        await update.message.reply_text("❌ Нужно ответить на сообщение соперника!")
        return

    user2 = update.message.reply_to_message.from_user
    user2_id = user2.id
    user2_name = user2.first_name

    if user1_id == user2_id:
        await update.message.reply_text("❌ Нельзя вызвать самого себя!")
        return

    if chat_id in duels:
        await update.message.reply_text("❌ В этом чате уже идёт дуэль!")
        return

    duels[chat_id] = {
        'user1': user1_id, 'user2': user2_id,
        'name1': user1_name, 'name2': user2_name,
        'score1': 0, 'score2': 0,
        'turn': user1_id,
        'last_roll1': None, 'last_roll2': None,
        'awaiting_accept': True,
        'challenger': user1_id
    }

    keyboard = InlineKeyboardMarkup([
        [InlineKeyboardButton("✅ ПРИНЯТЬ", callback_data="accept")],
        [InlineKeyboardButton("❌ ОТКЛОНИТЬ", callback_data="decline")],
        [InlineKeyboardButton("⚡ ОТМЕНА", callback_data="cancel")]
    ])

    await update.message.reply_text(
        f"⚔️ *{user1_name}* вызывает *{user2_name}* на дуэль!\n\n"
        f"🎯 До побед: 3\n\n"
        f"👇 *{user2_name}*, прими вызов:",
        parse_mode="Markdown",
        reply_markup=keyboard
    )

# ========== ОБРАБОТЧИК КНОПОК ==========
async def handle_buttons(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    chat_id = query.message.chat_id
    user = query.from_user
    user_id = user.id
    action = query.data

    print(f"🔘 Нажата кнопка: {action} от {user.first_name}")

    if chat_id not in duels:
        await query.edit_message_text("❌ Дуэль уже завершена.")
        return

    duel = duels[chat_id]

    if action == "cancel":
        if user_id not in (duel['user1'], duel['user2']):
            await query.answer("Вы не участник!", show_alert=True)
            return
        await query.edit_message_text(f"⚡ Дуэль отменена пользователем *{user.first_name}*.", parse_mode="Markdown")
        del duels[chat_id]
        return

    if action == "decline":
        if user_id != duel['user2']:
            await query.answer("Только вызванный может отклонить!", show_alert=True)
            return
        await query.edit_message_text(f"❌ *{user.first_name}* отклонил дуэль!", parse_mode="Markdown")
        del duels[chat_id]
        return

    if action == "accept":
        if user_id != duel['user2']:
            await query.answer("Только вызванный может принять!", show_alert=True)
            return

        if not duel.get('awaiting_accept'):
            await query.answer("Дуэль уже началась!", show_alert=True)
            return

        duel['awaiting_accept'] = False
        duel['turn'] = duel['challenger']

        keyboard = InlineKeyboardMarkup([
            [InlineKeyboardButton("🎲 СКОПИРОВАТЬ КУБИК", copy_text="🎲")],
            [InlineKeyboardButton("🏳️ СДАТЬСЯ", callback_data="surrender")],
            [InlineKeyboardButton("⚡ ОТМЕНИТЬ", callback_data="cancel")]
        ])

        await query.edit_message_text(
            f"🎲 *ДУЭЛЬ НАЧАЛАСЬ!* 🎲\n\n"
            f"⚔️ {duel['name1']} VS {duel['name2']} ⚔️\n"
            f"🎯 До побед: 3\n"
            f"📊 Счёт: 0 : 0\n\n"
            f"🔥 *Первым ходит:* {duel['name1']}\n\n"
            f"👇 Нажми на кнопку, скопируй 🎲 и брось в чат!",
            parse_mode="Markdown",
            reply_markup=keyboard
        )
        return

    if action == "surrender":
        if user_id not in (duel['user1'], duel['user2']):
            await query.answer("Вы не участник!", show_alert=True)
            return

        if duel.get('awaiting_accept'):
            await query.answer("Дуэль ещё не началась!", show_alert=True)
            return

        winner_id = duel['user2'] if user_id == duel['user1'] else duel['user1']
        winner_name = duel['name2'] if user_id == duel['user1'] else duel['name1']

        update_stats(chat_id, winner_id, True)
        update_stats(chat_id, user_id, False)

        await query.edit_message_text(
            f"🏳️ *{user.first_name}* сдался!\n\n"
            f"🎉 *Победитель:* {winner_name} 🎉\n"
            f"📊 Счёт: {duel['score1']} : {duel['score2']}",
            parse_mode="Markdown"
        )
        del duels[chat_id]
        return

# ========== БРОСОК КУБИКА ==========
async def handle_dice(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    user = update.effective_user
    user_id = user.id

    if chat_id not in duels:
        return

    duel = duels[chat_id]
    if duel.get('awaiting_accept'):
        return

    if user_id not in (duel['user1'], duel['user2']):
        return

    if duel['turn'] != user_id:
        name = duel['name1'] if duel['turn'] == duel['user1'] else duel['name2']
        await update.message.reply_text(f"⏳ Сейчас очередь *{name}*! Подождите.", parse_mode="Markdown")
        return

    if not update.message.dice or update.message.dice.emoji != "🎲":
        await update.message.reply_text("🎲 Брось анимированный кубик через панель стикеров!", parse_mode="Markdown")
        return

    roll = update.message.dice.value
    await update.message.reply_text(f"🎲 *{user.first_name}* выбросил: *{roll}*", parse_mode="Markdown")

    if user_id == duel['user1']:
        duel['last_roll1'] = roll
        duel['turn'] = duel['user2']
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"🎲 *{duel['name2']}*, теперь твоя очередь! Брось кубик!",
            parse_mode="Markdown"
        )
    else:
        duel['last_roll2'] = roll

        r1 = duel['last_roll1']
        r2 = duel['last_roll2']

        if r1 > r2:
            duel['score1'] += 1
            winner = duel['name1']
        elif r2 > r1:
            duel['score2'] += 1
            winner = duel['name2']
        else:
            winner = None

        msg = f"🎲 {duel['name1']} выбросил {r1}\n🎲 {duel['name2']} выбросил {r2}\n\n"
        if winner:
            msg += f"🏆 Раунд выиграл {winner}!\n"
        else:
            msg += f"🤝 Ничья!\n"
        msg += f"📊 Счёт: {duel['score1']} : {duel['score2']}"

        await update.message.reply_text(msg)

        duel['last_roll1'] = None
        duel['last_roll2'] = None

        if duel['score1'] >= 3:
            update_stats(chat_id, duel['user1'], True)
            update_stats(chat_id, duel['user2'], False)
            await update.message.reply_text(f"🎉 *{duel['name1']} ПОБЕДИЛ!* 🧸\nФинальный счёт: {duel['score1']} : {duel['score2']}", parse_mode="Markdown")
            del duels[chat_id]
        elif duel['score2'] >= 3:
            update_stats(chat_id, duel['user2'], True)
            update_stats(chat_id, duel['user1'], False)
            await update.message.reply_text(f"🎉 *{duel['name2']} ПОБЕДИЛ!* 🧸\nФинальный счёт: {duel['score1']} : {duel['score2']}", parse_mode="Markdown")
            del duels[chat_id]
        else:
            if winner == duel['name1']:
                duel['turn'] = duel['user1']
                next_name = duel['name1']
            elif winner == duel['name2']:
                duel['turn'] = duel['user2']
                next_name = duel['name2']
            else:
                duel['turn'] = duel['user1']
                next_name = duel['name1']

            await context.bot.send_message(
                chat_id=chat_id,
                text=f"🎲 *Следующий раунд!* Начинает {next_name}\n\nБрось кубик!",
                parse_mode="Markdown"
            )

# ========== КОМАНДЫ ==========
async def cmd_stats(update: Update, context: ContextTypes.DEFAULT_TYPE):
    wins, total = get_stats(update.effective_chat.id, update.effective_user.id)
    await update.message.reply_text(f"📊 *Ваша статистика:*\n🏆 Побед: {wins}\n🎲 Дуэлей: {total}", parse_mode="Markdown")

async def cmd_top(update: Update, context: ContextTypes.DEFAULT_TYPE):
    stats = get_all_stats(update.effective_chat.id)
    if not stats:
        await update.message.reply_text("📊 Нет статистики!")
        return
    text = "🏆 *Топ игроков:*\n"
    for i, (uid, wins, total) in enumerate(stats[:10], 1):
        text += f"{i}. ID `{uid}` — {wins} побед ({total} дуэлей)\n"
    await update.message.reply_text(text, parse_mode="Markdown")

async def cmd_surrender(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    user_id = update.effective_user.id

    if chat_id not in duels:
        await update.message.reply_text("❌ Нет активной дуэли!")
        return
    if duels[chat_id].get('awaiting_accept'):
        await update.message.reply_text("❌ Дуэль ещё не началась!")
        return
    if user_id not in (duels[chat_id]['user1'], duels[chat_id]['user2']):
        await update.message.reply_text("❌ Вы не участник!")
        return

    duel = duels[chat_id]
    winner_id = duel['user2'] if user_id == duel['user1'] else duel['user1']
    winner_name = duel['name2'] if user_id == duel['user1'] else duel['name1']

    update_stats(chat_id, winner_id, True)
    update_stats(chat_id, user_id, False)

    await update.message.reply_text(f"🏳️ Вы сдались!\n🎉 Победитель: {winner_name}\n📊 Счёт: {duel['score1']} : {duel['score2']}")
    del duels[chat_id]

async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        f"🎲 *Бот Дуэлей*\n\n"
        f"*/duel* — вызвать на дуэль (ответом на сообщение)\n"
        f"*/stats* — ваша статистика\n"
        f"*/top* — топ игроков\n"
        f"*/surrender* — сдаться\n"
        f"*/help* — справка",
        parse_mode="Markdown"
    )

# ========== АДМИН-КОМАНДЫ ==========
async def reset_duel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != ADMIN_ID:
        return
    chat_id = update.effective_chat.id
    if chat_id in duels:
        del duels[chat_id]
        await update.message.reply_text("✅ Дуэль сброшена")

async def clear_stats_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != ADMIN_ID:
        return
    clear_stats(update.effective_chat.id)
    await update.message.reply_text("✅ Статистика очищена")

# ========== НАСТРОЙКА МЕНЮ ==========
async def setup_commands(app):
    await app.bot.set_my_commands([
        BotCommand("duel", "Вызвать на дуэль"),
        BotCommand("stats", "Моя статистика"),
        BotCommand("top", "Топ игроков"),
        BotCommand("surrender", "Сдаться"),
        BotCommand("help", "Справка"),
    ])

# ========== ЗАПУСК ==========
def main():
    if not TOKEN:
        print("❌ Нет TOKEN")
        return

    init_db()
    app = Application.builder().token(TOKEN).post_init(setup_commands).build()

    app.add_handler(CommandHandler("duel", duel_command))
    app.add_handler(CommandHandler("stats", cmd_stats))
    app.add_handler(CommandHandler("top", cmd_top))
    app.add_handler(CommandHandler("surrender", cmd_surrender))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CommandHandler("reset_duel", reset_duel))
    app.add_handler(CommandHandler("clear_stats", clear_stats_cmd))

    app.add_handler(CallbackQueryHandler(handle_buttons))
    app.add_handler(MessageHandler(filters.Dice.ALL, handle_dice))

    print("🎲 Бот запущен!")
    app.run_polling()

if __name__ == "__main__":
    main()
