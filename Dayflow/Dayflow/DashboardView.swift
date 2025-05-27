//
//  DashboardView.swift
//  Dayflow
//
//  Dashboard view with todo list and analytics cards for personal tracking
//

import SwiftUI

// MARK: - Data Models

enum CardType: String, Codable, CaseIterable {
    case count = "Count"
    case time = "Time"
    
    var icon: String {
        switch self {
        case .count: return "number.circle"
        case .time: return "clock"
        }
    }
}

struct DashboardCard: Identifiable, Codable {
    let id = UUID()
    var question: String
    var type: CardType
    var todayValue: Double // For count: number, for time: minutes
    
    var formattedTodayValue: String {
        switch type {
        case .count:
            return "\(Int(todayValue))"
        case .time:
            let hours = Int(todayValue) / 60
            let minutes = Int(todayValue) % 60
            if hours > 0 {
                return "\(hours)h \(minutes)m"
            } else {
                return "\(minutes) min"
            }
        }
    }
    
    var unit: String {
        switch type {
        case .count:
            return "times"
        case .time:
            return ""
        }
    }
}

struct TodoItem: Identifiable, Codable {
    let id = UUID()
    var title: String
    var isCompleted: Bool = false
    var createdDate: Date = Date()
}

// MARK: - Main Dashboard View

struct DashboardView: View {
    @State private var cards: [DashboardCard] = []
    @State private var todos: [TodoItem] = []
    @State private var showingAddCard = false
    @State private var editingCard: DashboardCard?
    @State private var showingAddTodo = false
    @State private var newTodoText = ""
    
    private let storageManager = StorageManager.shared
    @State private var currentDayString: String = ""
    
    private let maxCards = 6
    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Todo List Section
                todoSection
                
                // Analytics Cards Section
                analyticsSection
            }
            .padding(24)
        }
        .background(Color.white)
        .sheet(isPresented: $showingAddCard) {
            AddCardView { newCard in
                if cards.count < maxCards {
                    let dbQuestion = DashboardQuestionDB(
                        question: newCard.question,
                        type: newCard.type.rawValue.lowercased()
                    )
                    if let questionId = storageManager.saveDashboardQuestion(question: dbQuestion) {
                        // Mark for reprocess so it gets evaluated against today's data
                        storageManager.markQuestionForReprocess(questionId: questionId, day: currentDayString)
                    }
                    loadData()
                }
            }
        }
        .sheet(item: $editingCard) { card in
            EditCardView(card: card) { updatedCard in
                if let dbCard = findDatabaseCardForDashboardCard(updatedCard) {
                    storageManager.updateDashboardQuestion(
                        questionId: dbCard.id!,
                        question: updatedCard.question,
                        type: updatedCard.type.rawValue.lowercased()
                    )
                    // Mark for reprocess after editing
                    storageManager.markQuestionForReprocess(questionId: dbCard.id!, day: currentDayString)
                    loadData()
                }
            } onDelete: {
                if let dbCard = findDatabaseCardForDashboardCard(card) {
                    storageManager.deleteDashboardQuestion(questionId: dbCard.id!)
                    loadData()
                }
            }
        }
        .onAppear {
            loadData()
        }
    }
    
    // MARK: - Todo Section
    
    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today's Tasks")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: { showingAddTodo = true }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title2)
                }
            }
            
            if todos.isEmpty {
                Text("No tasks yet. Add one to get started!")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach($todos) { $todo in
                        TodoItemView(todo: $todo) {
                            // Removed saveTodos call
                        } onDelete: {
                            todos.removeAll { $0.id == todo.id }
                            // Removed saveTodos call
                        }
                    }
                }
            }
            
            if showingAddTodo {
                HStack {
                    TextField("Add a task...", text: $newTodoText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onSubmit {
                            addNewTodo()
                        }
                    
                    Button("Add") {
                        addNewTodo()
                    }
                    .disabled(newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Button("Cancel") {
                        showingAddTodo = false
                        newTodoText = ""
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Analytics Section
    
    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Personal Analytics")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal)
            
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(cards) { card in
                    AnalyticsCardView(card: card)
                        .onTapGesture {
                            editingCard = card
                        }
                }
                
                if cards.count < maxCards {
                    AddCardButton {
                        showingAddCard = true
                    }
                }
            }
            .padding(.horizontal)
        }
    }
    
    // MARK: - Helper Methods
    
    private func addNewTodo() {
        let trimmedText = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        let newTodo = TodoItemDB(title: trimmedText)
        _ = storageManager.saveTodoForDay(todo: newTodo, day: currentDayString)
        
        newTodoText = ""
        showingAddTodo = false
        loadData()
    }
    
    private func loadData() {
        let dayInfo = Date().getDayInfoFor4AMBoundary()
        currentDayString = dayInfo.dayString
        
        let dbQuestions = storageManager.fetchDashboardQuestions()
        let dbAnswers = storageManager.fetchAllDashboardAnswersForDay(day: currentDayString)
        
        // Convert database questions to dashboard cards
        cards = dbQuestions.compactMap { dbQuestion in
            guard let questionId = dbQuestion.id else { return nil }
            
            // Find current value for this question today
            let currentAnswer = dbAnswers.first { $0.questionId == questionId }
            let todayValue = currentAnswer?.currentValue ?? 0.0
            
            // Convert type string back to CardType
            let cardType: CardType
            switch dbQuestion.type.lowercased() {
            case "time": cardType = .time
            case "count": cardType = .count
            default: cardType = .count
            }
            
            return DashboardCard(
                question: dbQuestion.question,
                type: cardType,
                todayValue: todayValue
            )
        }
        
        let dbTodos = storageManager.fetchTodosForDay(day: currentDayString)
        todos = dbTodos.map { dbTodo in
            TodoItem(
                title: dbTodo.title,
                isCompleted: dbTodo.isCompleted,
                createdDate: dbTodo.createdAt
            )
        }
    }
    
    private func findDatabaseCardForDashboardCard(_ dashboardCard: DashboardCard) -> DashboardQuestionDB? {
        let dbQuestions = storageManager.fetchDashboardQuestions()
        return dbQuestions.first { $0.question == dashboardCard.question }
    }
}

// MARK: - Component Views

struct TodoItemView: View {
    @Binding var todo: TodoItem
    var onToggle: () -> Void
    var onDelete: () -> Void
    @State private var isHovering = false
    
    private let storageManager = StorageManager.shared
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                todo.isCompleted.toggle()
                
                let dayInfo = Date().getDayInfoFor4AMBoundary()
                let currentDayString = dayInfo.dayString
                let dbTodos = storageManager.fetchTodosForDay(day: currentDayString)
                
                if let dbTodo = dbTodos.first(where: { $0.title == todo.title }) {
                    if let todoId = dbTodo.id {
                        storageManager.updateTodoCompletion(todoId: todoId, day: currentDayString, isCompleted: todo.isCompleted)
                    }
                }
                
                onToggle()
            }) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(todo.isCompleted ? Color(hex: 0x4CAF50) : Color(hex: 0xE0E0E0))
                    .font(.system(size: 20))
            }
            .buttonStyle(PlainButtonStyle())
            
            Text(todo.title)
                .strikethrough(todo.isCompleted)
                .foregroundColor(todo.isCompleted ? Color.gray : Color.black)
                .font(.system(size: 16))
            
            Spacer()
            
            if isHovering {
                Button(action: {
                    let dayInfo = Date().getDayInfoFor4AMBoundary()
                    let currentDayString = dayInfo.dayString
                    let dbTodos = storageManager.fetchTodosForDay(day: currentDayString)
                    
                    if let dbTodo = dbTodos.first(where: { $0.title == todo.title }) {
                        if let todoId = dbTodo.id {
                            storageManager.updateTodoCompletion(todoId: todoId, day: currentDayString, isCompleted: true) // Mark as deleted by setting completed
                        }
                    }
                    
                    onDelete()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(Color.gray)
                        .font(.system(size: 14))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isHovering ? Color(hex: 0xF8F8F8) : Color.clear)
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

struct AnalyticsCardView: View {
    let card: DashboardCard
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.question)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(hex: 0x6B7280))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(card.formattedTodayValue)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(Color.black)
                    
                    if !card.unit.isEmpty {
                        Text(card.unit)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(Color(hex: 0x9CA3AF))
                    }
                }
            }
            
            Spacer()
        }
        .padding(20)
        .frame(height: 140)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xF9FAFB))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
        )
    }
}

struct AddCardButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(Color(hex: 0x3B82F6))
                
                Text("Add Card")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(hex: 0x6B7280))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: 140)
            .background(Color(hex: 0xF9FAFB))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundColor(Color(hex: 0xE5E7EB))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Add/Edit Card Views

struct AddCardView: View {
    @Environment(\.dismiss) var dismiss
    @State private var question = ""
    @State private var selectedType: CardType = .count
    let onAdd: (DashboardCard) -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Add Analytics Card")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Question")
                    .font(.headline)
                TextField("e.g., How many times did I check email?", text: $question)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Type")
                    .font(.headline)
                Picker("Type", selection: $selectedType) {
                    ForEach(CardType.allCases, id: \.self) { type in
                        HStack {
                            Image(systemName: type.icon)
                            Text(type.rawValue)
                        }
                        .tag(type)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                
                Spacer()
                
                Button("Add Card") {
                    let newCard = DashboardCard(
                        question: question,
                        type: selectedType,
                        todayValue: 0
                    )
                    onAdd(newCard)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}

struct EditCardView: View {
    @Environment(\.dismiss) var dismiss
    @State private var question: String
    let card: DashboardCard
    let onSave: (DashboardCard) -> Void
    let onDelete: () -> Void
    
    init(card: DashboardCard, onSave: @escaping (DashboardCard) -> Void, onDelete: @escaping () -> Void) {
        self.card = card
        self._question = State(initialValue: card.question)
        self.onSave = onSave
        self.onDelete = onDelete
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Card")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Question")
                    .font(.headline)
                TextField("Question", text: $question)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            Spacer()
            
            HStack {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                
                Button("Save") {
                    var updatedCard = card
                    updatedCard.question = question
                    onSave(updatedCard)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 250)
    }
}

// MARK: - Preview

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
    }
}
