VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
END
Attribute VB_Name = "BDados"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = True
Option Explicit

'Insere o curso e a string e ele retorna qual � o periodo deste curso nesta string
Sub analisaString(ByVal op As Boolean, ByRef vetorLinha, ByRef vetorColuna, ByRef tam, ByVal txt As String)
    Dim horarioTxt() As String
    Dim dadosTxt() As String
    Dim auxTxt As Variant
    Dim somaAux As Integer

    If op = True Then
        somaAux = 1
    Else
        somaAux = 0
    End If
    horarioTxt = Split(txt, ";")
    tam = 0

    For Each auxTxt In horarioTxt
        dadosTxt = Split(auxTxt, ",")
        vetorLinha(tam) = dadosTxt(0)
        vetorColuna(tam) = dadosTxt(1) - somaAux
        tam = tam + 1
    Next
End Sub
'Retorna qual � o periodo de uma dada string e um dado curso
Function retornaPeriodo(ByVal curso As Integer, ByVal txt As String) As Integer
    Dim vetorLinha(12), vetorColuna(12), tam, i As Integer
    retornaPeriodo = 0
    Call BDados.analisaString(False, vetorLinha, vetorColuna, tam, txt)
    For i = 0 To (tam - 1) 'Peencher os checkBoxs dos Cursos
        If curso = vetorColuna(i) Then
            retornaPeriodo = vetorLinha(i)
            Exit For
        End If
    Next i
End Function

Sub limpaPeriodo(ByVal isDocente As Boolean, ByVal posicaoLinha As Integer)
    Dim rng As Range
    Dim rCell As Range
    If isDocente = False Then
        With Horario.Range(Horario.Cells(posicaoLinha + 28, 2), Horario.Cells(posicaoLinha + 37, 12))
                .ClearContents
                .Interior.Color = RGB(255, 255, 255)
        End With
        Set rng = Horario.Range(Horario.Cells(posicaoLinha + 2, 3), Horario.Cells(posicaoLinha + 25, 12)) 'Defina seu Intervalo
    Else
        Set rng = Docentes.Range(Docentes.Cells(posicaoLinha + 2, 3), Docentes.Cells(posicaoLinha + 25, 12)) 'Defina seu Intervalo
    End If
    For Each rCell In rng.Cells
        With rCell
            If .MergeCells Then
                .MergeArea.ClearContents
                .MergeArea.Interior.Color = RGB(255, 255, 255)
            Else
                .ClearContents
                .Interior.Color = RGB(255, 255, 255)
            End If
        End With
    Next rCell
End Sub

Function identificaCurso(ByVal cursoTxt As String) As Integer 'Identifica qual � o curso
    Dim i As Integer
    identificaCurso = 0
    For i = 3 To 7
        If UCase(BDados.Cells(i, 13).Text) Like UCase(cursoTxt) Then
            identificaCurso = BDados.Cells(i, 12)
            Exit For
        End If
    Next i
End Function

Function extraiCurso(ByVal opcao As Boolean) As String
    Dim i, j As Integer
    extraiCurso = ""
    For i = 1 To 5
        If Not HorarioDisciplinaForm.Controls("TextBox" & i).Value Like "" Then
            extraiCurso = extraiCurso + ";" + CStr(HorarioDisciplinaForm.Controls("TextBox" & i).Value) + "," + CStr(i)
            If opcao = True Then
                HorarioDisciplinaForm.Controls("TextBox" & i).Value = "" 'Reseta os checkBoxs
            End If
        End If
    Next i
    i = Len(extraiCurso)
    If i > 0 Then
        extraiCurso = Right(extraiCurso, i - 1)
    End If
End Function

Function extraiHorario(ByVal opcao As Boolean) As String
    Dim i, j As Integer
    extraiHorario = ""
    For i = 1 To 5
        For j = 1 To 12
            If HorarioDisciplinaForm.Controls("CheckBox" & i & j).Value Then
                extraiHorario = extraiHorario + ";" + CStr(j) + "," + CStr(i + 1)
                If opcao = True Then
                    HorarioDisciplinaForm.Controls("CheckBox" & i & j).Value = False 'Reseta os checkBoxs
                End If
            End If
        Next j
    Next i
    i = Len(extraiHorario)
    If i > 0 Then
        extraiHorario = Right(extraiHorario, i - 1)
    End If
End Function

Sub mergedCellAutoFit()
    Dim NewRwHt As Single
    Dim cWdth As Single, MrgeWdth As Single
    Dim c As Range, cc As Range
    Dim ma As Range
    With ActiveCell
        If .MergeCells And .WrapText Then
            'ActiveSheet.Unprotect Password:="justme"
            Set c = ActiveCell.Cells(1, 1)
            cWdth = c.ColumnWidth
            Set ma = c.MergeArea
            For Each cc In ma.Cells
                MrgeWdth = MrgeWdth + cc.ColumnWidth
            Next
            Application.ScreenUpdating = False
            ma.MergeCells = False
            c.ColumnWidth = MrgeWdth
            c.EntireRow.AutoFit
            NewRwHt = c.RowHeight
            c.ColumnWidth = cWdth
            ma.MergeCells = True
            ma.RowHeight = NewRwHt
            cWdth = 0: MrgeWdth = 0
            'ActiveSheet.Protect Password:="justme"
        End If
    End With
End Sub

Sub preencheDisciplina(ByRef worksheetsTxt As String, ByRef countVarredura, ByRef posicaoLinha, ByRef posicaoDisciplina, ByRef colorIndex, ByRef siglaAnterior)
    Dim tiposColor As Variant
    Dim vetorLinha(12), vetorColuna(12), tam, i, j As Integer

    Call BDados.analisaString(True, vetorLinha, vetorColuna, tam, BDados.Cells(countVarredura, 3).Value)
    tiposColor = Array(RGB(173, 216, 230), RGB(255, 182, 193), RGB(250, 128, 114), RGB(51, 204, 204), RGB(240, 230, 140), RGB(153, 153, 255), RGB(152, 251, 152), RGB(255, 255, 0), RGB(173, 255, 47), RGB(218, 112, 214))

    If Not siglaAnterior Like BDados.Cells(countVarredura, 5).Value Then
        colorIndex = colorIndex + 1
        siglaAnterior = BDados.Cells(countVarredura, 5).Value
        If worksheetsTxt Like "Horario" Then
            Worksheets(worksheetsTxt).Cells(posicaoDisciplina, 2).Value = BDados.Cells(countVarredura, 4).Value 'Codigo
            Worksheets(worksheetsTxt).Cells(posicaoDisciplina, 3).Value = BDados.Cells(countVarredura, 5).Value 'Sigla
            Worksheets(worksheetsTxt).Cells(posicaoDisciplina, 3).Interior.Color = tiposColor(colorIndex)
            Worksheets(worksheetsTxt).Cells(posicaoDisciplina, 4).Value = BDados.Cells(countVarredura, 6).Value 'Disciplina
            Worksheets(worksheetsTxt).Cells(posicaoDisciplina, 9).Value = BDados.Cells(countVarredura, 8).Value 'Docente
            Worksheets(worksheetsTxt).Cells(posicaoDisciplina, 11).Value = BDados.Cells(countVarredura, 9).Value 'Sala
            Worksheets(worksheetsTxt).Range(Worksheets(worksheetsTxt).Cells(posicaoDisciplina, 9), Worksheets(worksheetsTxt).Cells(posicaoDisciplina, 12)).Select
            Call mergedCellAutoFit
            posicaoDisciplina = posicaoDisciplina + 1
        End If
    End If
    If (tam > 0) Then
        For i = 0 To (tam - 1)
            Worksheets(worksheetsTxt).Range(Worksheets(worksheetsTxt).Cells(posicaoLinha + 2 * vetorLinha(i), (vetorColuna(i) * 2) + 1), Worksheets(worksheetsTxt).Cells(posicaoLinha + 1 + 2 * vetorLinha(i), (vetorColuna(i) * 2) + 1)).Select
            If Not ActiveCell.MergeArea.Cells(1, 1).Value Like "" Then
                ActiveCell.MergeArea.MergeCells = False
                ActiveCell.MergeArea.Cells(2, 1).Font.Size = 14
                ActiveCell.MergeArea.Cells(2, 1).Value = BDados.Cells(countVarredura, 5).Value
                ActiveCell.MergeArea.Cells(2, 1).Interior.Color = tiposColor(colorIndex)
            Else
                Worksheets(worksheetsTxt).Range(Worksheets(worksheetsTxt).Cells(posicaoLinha + 2 * vetorLinha(i), (vetorColuna(i) * 2) + 1), Worksheets(worksheetsTxt).Cells(posicaoLinha + 1 + 2 * vetorLinha(i), (vetorColuna(i) * 2) + 1)).MergeCells = True
                ActiveCell.MergeArea.Cells(1, 1).Value = BDados.Cells(countVarredura, 5).Value
                ActiveCell.MergeArea.Cells(1, 1).Interior.Color = tiposColor(colorIndex)
            End If

            Worksheets(worksheetsTxt).Range(Worksheets(worksheetsTxt).Cells(posicaoLinha + 2 * vetorLinha(i), (vetorColuna(i) * 2) + 2), Worksheets(worksheetsTxt).Cells(posicaoLinha + 1 + 2 * vetorLinha(i), (vetorColuna(i) * 2) + 2)).Select
            If Not ActiveCell.MergeArea.Cells(1, 1).Value Like "" Then
                ActiveCell.MergeArea.MergeCells = False
                ActiveCell.MergeArea.Cells(2, 1).Font.Size = 14
                ActiveCell.MergeArea.Cells(2, 1).Value = CStr(BDados.Cells(countVarredura, 7).Value)
                ActiveCell.MergeArea.Cells(2, 1).Interior.Color = tiposColor(colorIndex)
            Else
                Worksheets(worksheetsTxt).Range(Worksheets(worksheetsTxt).Cells(posicaoLinha + 2 * vetorLinha(i), (vetorColuna(i) * 2) + 2), Worksheets(worksheetsTxt).Cells(posicaoLinha + 1 + 2 * vetorLinha(i), (vetorColuna(i) * 2) + 2)).MergeCells = True
                ActiveCell.MergeArea.Cells(1, 1).Value = CStr(BDados.Cells(countVarredura, 7).Value)
                ActiveCell.MergeArea.Cells(1, 1).Interior.Color = tiposColor(colorIndex)
            End If

        Next i
    End If

End Sub

Sub atualizaCheckBox(ByRef result, ByRef countVarredura)
    Dim vetorLinha(12), vetorColuna(12), tam, i As Integer
    If result(0) Like BDados.Cells(countVarredura, 4).Value And result(1) Like BDados.Cells(countVarredura, 6).Value And result(2) Like CStr(BDados.Cells(countVarredura, 7).Value) Then
        Call BDados.analisaString(True, vetorLinha, vetorColuna, tam, BDados.Cells(countVarredura, 3).Value)
        For i = 0 To (tam - 1) 'Peencher os checkBoxs dos Horarios
            HorarioDisciplinaForm.Controls("CheckBox" + CStr(vetorColuna(i)) + CStr(vetorLinha(i))).Value = True
        Next i
        Call BDados.analisaString(False, vetorLinha, vetorColuna, tam, BDados.Cells(countVarredura, 2).Value)
        For i = 0 To (tam - 1) 'Peencher os checkBoxs dos Cursos
            HorarioDisciplinaForm.Controls("TextBox" + CStr(vetorColuna(i))).Value = vetorLinha(i)
        Next i
    End If
End Sub

Sub preencherTodosPeriodo(ByVal cursoTxt As String)
    Dim curso, periodo, periodoAnterior, posicaoDisciplina, posicaoLinha As Integer
    Dim countVarredura, colorIndex As Integer
    Dim siglaAnterior As String

    curso = identificaCurso(cursoTxt) 'Identifica qual � o curso
    siglaAnterior = ""
    periodoAnterior = 0
    countVarredura = 3
    Application.ScreenUpdating = False
    Do While Len(BDados.Cells(countVarredura, 2).Value) > 0
        periodo = retornaPeriodo(curso, BDados.Cells(countVarredura, 2).Text)
        If periodo <> 0 Then
            If periodo <> periodoAnterior Then
                periodoAnterior = periodo
                posicaoDisciplina = (periodo - 1) * 42 + 33
                posicaoLinha = (periodo - 1) * 42 + 5
                colorIndex = -1
                'Apaga toda a planilha do periodo e muda a cor de interior para branco
                Call limpaPeriodo(False, posicaoLinha)
            End If
            Call preencheDisciplina("Horario", countVarredura, posicaoLinha, posicaoDisciplina, colorIndex, siglaAnterior)
        End If
        countVarredura = countVarredura + 1
    Loop
    Application.ScreenUpdating = True
    'MsgBox ("Inser��o Completa")
    'Application.Wait (Now + TimeValue("0:00:02"))
    'Horario.Cells(7, 3).Value = tam
End Sub

Sub preencherPeriodo(ByVal opcaoDesejada As Integer, ByVal disciplinaDesejada As String, ByVal periodoDesejado As Integer, ByVal cursoTxt As String)
    ' Se opcaoDesejada = 1 apenas Carregar Formulario pois CombBox teve sua selec�o alterada
    ' Se opcaoDesejada = 2 apenas Salvar Mudan�as do CombBox no BDados
    ' Se opcaoDesejada = 3 apenas Preencher Planilha de Hor�rios
    ' Se opcaoDesejada = 4 apenas Preencher Disciplinas no CombBox


    Dim horarioExtraidoTxt, cursoExtraidoTxt, result() As String
    Dim i, j, curso, periodo, posicaoDisciplina, posicaoLinha As Integer
    Dim vetorLinha(12), vetorColuna(12), tam, countVarredura, colorIndex As Integer
    Dim siglaAnterior As String

    Application.ScreenUpdating = False
    result = Split(disciplinaDesejada, "_")
    curso = identificaCurso(cursoTxt) 'Identifica qual � o curso
    colorIndex = -1
    siglaAnterior = ""
    countVarredura = 3
    posicaoDisciplina = (periodoDesejado - 1) * 42 + 33
    posicaoLinha = (periodoDesejado - 1) * 42 + 5

    If opcaoDesejada = 1 And Not disciplinaDesejada Like "" Then 'Salvar
        horarioExtraidoTxt = extraiHorario(True)
        cursoExtraidoTxt = extraiCurso(True)
    ElseIf opcaoDesejada = 2 And Not disciplinaDesejada Like "" Then 'Salvar
        horarioExtraidoTxt = extraiHorario(False)
        cursoExtraidoTxt = extraiCurso(False)
    ElseIf opcaoDesejada = 3 Then 'Apaga toda a planilha do periodo e muda a cor de interior para branco
        Call limpaPeriodo(False, posicaoLinha)
    ElseIf opcaoDesejada = 4 Then 'Preencher CombBox
        HorarioDisciplinaForm.CBDiscipina.Clear
    End If

    Do While Len(BDados.Cells(countVarredura, 2).Value) > 0
        periodo = BDados.retornaPeriodo(curso, BDados.Cells(countVarredura, 2).Value)
        If periodo > periodoDesejado Then
            Exit Do
        ElseIf periodo = periodoDesejado Then
            If opcaoDesejada = 1 And Not disciplinaDesejada Like "" Then 'Carregar Formulario pois CombBox teve sua selec�o alterada
                Call atualizaCheckBox(result, countVarredura)
            ElseIf opcaoDesejada = 2 And Not disciplinaDesejada Like "" Then 'Salvar Mudan�as do CombBox no BDados
                If result(0) Like BDados.Cells(countVarredura, 4).Value And result(1) Like BDados.Cells(countVarredura, 6).Value And result(2) Like CStr(BDados.Cells(countVarredura, 7).Value) Then
                    BDados.Cells(countVarredura, 3).Value = horarioExtraidoTxt
                    BDados.Cells(countVarredura, 2).Value = cursoExtraidoTxt
                End If
            ElseIf opcaoDesejada = 3 Then 'Preencher Planilha de Hor�rios
                Call preencheDisciplina("Horario", countVarredura, posicaoLinha, posicaoDisciplina, colorIndex, siglaAnterior)
            ElseIf opcaoDesejada = 4 Then 'Preencher Disciplinas no CombBox
                HorarioDisciplinaForm.CBDiscipina.AddItem (BDados.Cells(countVarredura, 4).Value + "_" + BDados.Cells(countVarredura, 6).Value + "_" + CStr(BDados.Cells(countVarredura, 7).Value) + "_" + BDados.Cells(countVarredura, 8).Value + "_" + BDados.Cells(countVarredura, 9).Value + "_" + BDados.Cells(countVarredura, 5).Value + "_" + CStr(countVarredura))
            End If
        End If
        countVarredura = countVarredura + 1
    Loop
    Application.ScreenUpdating = True
End Sub

Sub preencherProfessor(ByVal cursoDesejado, ByVal posicaoDocente, ByVal docenteDesejado)
    Dim curso, countVarredura, colorIndex As Integer
    Dim siglaAnterior As String

    Application.ScreenUpdating = False
    Call limpaPeriodo(True, posicaoDocente)
    curso = identificaCurso(cursoDesejado) 'Identifica qual � o curso
    colorIndex = -1
    countVarredura = 3

    Do While Not BDados.Cells(countVarredura, 2).Value Like ""
        If docenteDesejado = BDados.Cells(countVarredura, 8).Value Then
            Call preencheDisciplina("Docentes", countVarredura, posicaoDocente, 0, colorIndex, siglaAnterior)
        End If
        countVarredura = countVarredura + 1
    Loop
    Application.ScreenUpdating = True
End Sub
