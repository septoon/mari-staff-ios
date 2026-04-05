import Foundation

enum MariStaffSampleData {
    static let primary: MariStaffSnapshot = {
        let currentUser = StaffMember(
            id: "staff-owner",
            name: "Айарпи Акопян",
            role: .owner,
            position: "Управляющая",
            phone: "+7 978 677-81-30",
            email: "beautymari2024@gmail.com",
            isCurrentUser: true
        )
        let staff = [
            currentUser,
            StaffMember(
                id: "staff-nails",
                name: "Амаля Мензатова",
                role: .master,
                position: "Маникюр",
                phone: "+7 978 318-89-83",
                email: "amalya@maribeauty.ru",
                isCurrentUser: false
            ),
            StaffMember(
                id: "staff-brows",
                name: "Марина Савченко",
                role: .admin,
                position: "Бровист",
                phone: "+7 978 144-22-10",
                email: "marina@maribeauty.ru",
                isCurrentUser: false
            ),
            StaffMember(
                id: "staff-hair",
                name: "Елена Воронова",
                role: .master,
                position: "Парикмахер",
                phone: "+7 978 900-41-17",
                email: "elena@maribeauty.ru",
                isCurrentUser: false
            )
        ]

        let today = day(hour: 10, minute: 0)

        let appointments = [
            Appointment(
                id: "apt-1",
                clientName: "Мария Зотова",
                serviceName: "Маникюр + укрепление",
                staffID: staff[1].id,
                staffName: staff[1].name,
                startsAt: day(hour: 10, minute: 0),
                durationMinutes: 90,
                revenue: 3200,
                status: .confirmed,
                note: "Первый визит, важна быстрая навигация по карте клиента."
            ),
            Appointment(
                id: "apt-2",
                clientName: "София Минасян",
                serviceName: "Окрашивание бровей",
                staffID: staff[2].id,
                staffName: staff[2].name,
                startsAt: day(hour: 11, minute: 30),
                durationMinutes: 45,
                revenue: 1800,
                status: .pending,
                note: "Уточнить аллергию на краску."
            ),
            Appointment(
                id: "apt-3",
                clientName: "Ирина Сердюк",
                serviceName: "Стрижка + укладка",
                staffID: staff[3].id,
                staffName: staff[3].name,
                startsAt: day(hour: 13, minute: 0),
                durationMinutes: 120,
                revenue: 4700,
                status: .arrived,
                note: "VIP-клиент, добавить рекомендацию по домашнему уходу."
            ),
            Appointment(
                id: "apt-4",
                clientName: "Ксения Агапова",
                serviceName: "Педикюр smart",
                staffID: staff[1].id,
                staffName: staff[1].name,
                startsAt: day(hour: 15, minute: 30),
                durationMinutes: 75,
                revenue: 3600,
                status: .confirmed,
                note: nil
            ),
            Appointment(
                id: "apt-5",
                clientName: "Анна Шевцова",
                serviceName: "Ламинирование ресниц",
                staffID: staff[2].id,
                staffName: staff[2].name,
                startsAt: day(hour: 17, minute: 0),
                durationMinutes: 60,
                revenue: 2900,
                status: .pending,
                note: "Отправить фото до/после в Telegram-канал."
            ),
            Appointment(
                id: "apt-6",
                clientName: "Юлия Макарова",
                serviceName: "Консультация по уходу",
                staffID: staff[0].id,
                staffName: staff[0].name,
                startsAt: day(hour: 18, minute: 30),
                durationMinutes: 30,
                revenue: 0,
                status: .confirmed,
                note: "Разобрать жалобу по прошлой записи."
            ),
            Appointment(
                id: "apt-7",
                clientName: "Дарья Платонова",
                serviceName: "Маникюр nude",
                staffID: staff[1].id,
                staffName: staff[1].name,
                startsAt: day(dayOffset: -3, hour: 11, minute: 0),
                durationMinutes: 75,
                revenue: 2800,
                status: .confirmed,
                note: "Уточнить форму на следующий визит."
            ),
            Appointment(
                id: "apt-8",
                clientName: "Алина Осипенко",
                serviceName: "Консультация + подбор ухода",
                staffID: staff[0].id,
                staffName: staff[0].name,
                startsAt: day(dayOffset: -1, hour: 14, minute: 0),
                durationMinutes: 60,
                revenue: 1200,
                status: .pending,
                note: "Нужен follow-up после посещения."
            ),
            Appointment(
                id: "apt-9",
                clientName: "Екатерина Латыпова",
                serviceName: "Архитектура бровей",
                staffID: staff[2].id,
                staffName: staff[2].name,
                startsAt: day(dayOffset: 1, hour: 12, minute: 30),
                durationMinutes: 50,
                revenue: 2100,
                status: .confirmed,
                note: "Клиентка после отпуска, без хны."
            ),
            Appointment(
                id: "apt-10",
                clientName: "Валерия Самойлова",
                serviceName: "Стрижка каре",
                staffID: staff[3].id,
                staffName: staff[3].name,
                startsAt: day(dayOffset: 1, hour: 17, minute: 0),
                durationMinutes: 90,
                revenue: 3900,
                status: .arrived,
                note: "Добавить фото результата."
            ),
            Appointment(
                id: "apt-11",
                clientName: "Наталья Ким",
                serviceName: "Педикюр smart",
                staffID: staff[1].id,
                staffName: staff[1].name,
                startsAt: day(dayOffset: 2, hour: 9, minute: 30),
                durationMinutes: 80,
                revenue: 3400,
                status: .confirmed,
                note: "Просила окно с утра."
            ),
            Appointment(
                id: "apt-12",
                clientName: "Татьяна Мороз",
                serviceName: "Коррекция и окрашивание",
                staffID: staff[2].id,
                staffName: staff[2].name,
                startsAt: day(dayOffset: 4, hour: 13, minute: 0),
                durationMinutes: 60,
                revenue: 2400,
                status: .pending,
                note: "Проверить прошлый рецепт цвета."
            ),
            Appointment(
                id: "apt-13",
                clientName: "Ирина Сердюк",
                serviceName: "Комплексное окрашивание",
                staffID: staff[3].id,
                staffName: staff[3].name,
                startsAt: day(dayOffset: 5, hour: 11, minute: 0),
                durationMinutes: 180,
                revenue: 8600,
                status: .confirmed,
                note: "VIP, нужен кофе без сахара."
            ),
            Appointment(
                id: "apt-14",
                clientName: "Мария Зотова",
                serviceName: "Маникюр + дизайн",
                staffID: staff[1].id,
                staffName: staff[1].name,
                startsAt: day(dayOffset: 7, hour: 16, minute: 30),
                durationMinutes: 120,
                revenue: 4100,
                status: .confirmed,
                note: "Подготовить палитру нюдовых оттенков."
            ),
            Appointment(
                id: "apt-15",
                clientName: "Ольга Черненко",
                serviceName: "Укладка + уход",
                staffID: staff[3].id,
                staffName: staff[3].name,
                startsAt: day(dayOffset: 9, hour: 10, minute: 0),
                durationMinutes: 90,
                revenue: 4300,
                status: .pending,
                note: "Подтверждение за сутки."
            )
        ]

        let shifts = [
            ScheduleShift(
                id: "shift-1",
                staff: staff[0],
                startsAt: day(hour: 9, minute: 30),
                endsAt: day(hour: 19, minute: 0),
                bookedSlots: 4,
                totalSlots: 7
            ),
            ScheduleShift(
                id: "shift-2",
                staff: staff[1],
                startsAt: day(hour: 10, minute: 0),
                endsAt: day(hour: 20, minute: 0),
                bookedSlots: 5,
                totalSlots: 6
            ),
            ScheduleShift(
                id: "shift-3",
                staff: staff[2],
                startsAt: day(hour: 11, minute: 0),
                endsAt: day(hour: 18, minute: 0),
                bookedSlots: 3,
                totalSlots: 5
            ),
            ScheduleShift(
                id: "shift-4",
                staff: staff[3],
                startsAt: day(hour: 12, minute: 0),
                endsAt: day(hour: 21, minute: 0),
                bookedSlots: 4,
                totalSlots: 6
            )
        ]

        let clients = [
            ClientSummary(
                id: "client-1",
                name: "Мария Зотова",
                phone: "+7 978 710-44-90",
                lastVisit: day(dayOffset: -2, hour: 18, minute: 0),
                visits: 8,
                revenue: 25200,
                preferredService: "Маникюр",
                tier: .vip,
                discountPercent: 10
            ),
            ClientSummary(
                id: "client-2",
                name: "Ирина Сердюк",
                phone: "+7 978 645-01-08",
                lastVisit: day(dayOffset: -5, hour: 13, minute: 0),
                visits: 11,
                revenue: 48300,
                preferredService: "Волосы",
                tier: .vip,
                discountPercent: 15
            ),
            ClientSummary(
                id: "client-3",
                name: "София Минасян",
                phone: "+7 978 812-15-73",
                lastVisit: day(dayOffset: -12, hour: 12, minute: 30),
                visits: 3,
                revenue: 7100,
                preferredService: "Брови",
                tier: .new,
                discountPercent: 0
            ),
            ClientSummary(
                id: "client-4",
                name: "Ксения Агапова",
                phone: "+7 978 300-20-16",
                lastVisit: day(dayOffset: -1, hour: 16, minute: 0),
                visits: 6,
                revenue: 19800,
                preferredService: "Педикюр",
                tier: .loyal,
                discountPercent: 7
            ),
            ClientSummary(
                id: "client-5",
                name: "Анна Шевцова",
                phone: "+7 978 990-33-14",
                lastVisit: day(dayOffset: -8, hour: 14, minute: 0),
                visits: 4,
                revenue: 11600,
                preferredService: "Ресницы",
                tier: .loyal,
                discountPercent: 5
            ),
            ClientSummary(
                id: "client-6",
                name: "Юлия Макарова",
                phone: "+7 978 150-05-45",
                lastVisit: today,
                visits: 2,
                revenue: 4200,
                preferredService: "Консультации",
                tier: .new,
                discountPercent: 0
            )
        ]

        let notifications = [
            StaffNotificationItem(
                id: "note-1",
                title: "Новая запись в журнале",
                subtitle: "Мария Зотова записалась на маникюр к Амале",
                timestamp: day(hour: 9, minute: 12),
                kind: .booking,
                isUnread: true
            ),
            StaffNotificationItem(
                id: "note-2",
                title: "Изменение графика",
                subtitle: "Елена добавила вечернюю смену на воскресенье",
                timestamp: day(hour: 10, minute: 4),
                kind: .staff,
                isUnread: true
            ),
            StaffNotificationItem(
                id: "note-3",
                title: "Клиент запросил обратный звонок",
                subtitle: "Анна Шевцова просит подтвердить перенос на пятницу",
                timestamp: day(hour: 11, minute: 22),
                kind: .client,
                isUnread: false
            ),
            StaffNotificationItem(
                id: "note-4",
                title: "Публикация онлайн-записи",
                subtitle: "Контент клиентского сайта обновлен без ошибок",
                timestamp: day(hour: 12, minute: 40),
                kind: .system,
                isUnread: false
            ),
            StaffNotificationItem(
                id: "note-5",
                title: "Повторный клиент возвращается",
                subtitle: "Ирина Сердюк подтвердила комплексное окрашивание на завтра",
                timestamp: day(hour: 13, minute: 55),
                kind: .booking,
                isUnread: true
            )
        ]

        let shortcuts = [
            MoreShortcut(
                title: "Сотрудники",
                subtitle: "Роли, доступы и набор услуг команды.",
                systemImage: "person.crop.rectangle.stack.fill"
            ),
            MoreShortcut(
                title: "Аналитика",
                subtitle: "Выручка, загрузка и возврат клиентов.",
                systemImage: "chart.line.uptrend.xyaxis"
            ),
            MoreShortcut(
                title: "Онлайн-запись",
                subtitle: "Публичный сайт, публикация услуг и контента.",
                systemImage: "globe.badge.chevron.backward"
            ),
            MoreShortcut(
                title: "Политика",
                subtitle: "Тексты согласий и privacy policy для staff/client.",
                systemImage: "lock.doc.fill"
            ),
            MoreShortcut(
                title: "Настройки",
                subtitle: "Системные параметры студии и уведомлений.",
                systemImage: "slider.horizontal.3"
            ),
            MoreShortcut(
                title: "Поддержка",
                subtitle: "Контакт с поддержкой и быстрые служебные сценарии.",
                systemImage: "lifepreserver.fill"
            )
        ]

        return MariStaffSnapshot(
            studioName: "Mari Staff",
            activeDate: today,
            staff: staff,
            appointments: appointments,
            shifts: shifts,
            clients: clients,
            notifications: notifications,
            shortcuts: shortcuts
        )
    }()

    private static func day(dayOffset: Int = 0, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: .now)
        let shiftedDay = calendar.date(byAdding: .day, value: dayOffset, to: base) ?? base
        return calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: shiftedDay
        ) ?? shiftedDay
    }
}
