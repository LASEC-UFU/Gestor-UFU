VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
END
Attribute VB_Name = "Horario"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = True

Private Sub Editar1_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(1)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub Editar2_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(2)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub Editar3_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(3)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub Editar4_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(4)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub Editar5_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(5)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub Editar6_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(6)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub Editar7_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(7)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub Editar8_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(8)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub Editar9_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(9)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub Editar10_Click()
    HorarioDisciplinaForm.LPeriodo.Caption = CStr(10)
    HorarioDisciplinaForm.LCurso.Caption = Horario.Cells(3, 2).Value
    HorarioDisciplinaForm.Show
End Sub

Private Sub GerarTudo_Click()
    Call BDados.preencherTodosPeriodo(Horario.Cells(3, 2).Value)
End Sub
