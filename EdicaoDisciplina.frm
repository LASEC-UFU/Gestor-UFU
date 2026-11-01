VERSION 5.00
Begin {C62A69F0-16DC-11CE-9E98-00AA00574A4F} EdicaoDisciplina
   Caption         =   "Edi��o da Disciplina"
   ClientHeight    =   4800
   ClientLeft      =   120
   ClientTop       =   468
   ClientWidth     =   5616
   OleObjectBlob   =   "EdicaoDisciplina.frx":0000
   StartUpPosition =   1  'CenterOwner
End
Attribute VB_Name = "EdicaoDisciplina"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False
Option Explicit

Private Sub BCancel_Click()
    Unload Me
End Sub

Private Sub BSalvar_Click()
    Dim posicaoDisciplina As Integer
    Dim result() As String
    result = Split(HorarioDisciplinaForm.CBDiscipina.Text, "_")
    posicaoDisciplina = CInt(result(6))

    BDados.Cells(posicaoDisciplina, 4).Value = TCodigo.Value 'C�digo
    BDados.Cells(posicaoDisciplina, 6).Value = TNome.Value 'Nome da Disciplina
    BDados.Cells(posicaoDisciplina, 7).Value = TTurma.Value 'Turma
    BDados.Cells(posicaoDisciplina, 8).Value = TDocente.Value 'Docente
    BDados.Cells(posicaoDisciplina, 9).Value = TSala.Value 'Sala
    BDados.Cells(posicaoDisciplina, 5).Value = TSigla.Value 'Sigla

    Call BDados.preencherPeriodo(2, HorarioDisciplinaForm.discipinaTxt, CInt(LPeriodo.Caption), LCurso.Caption)
    Call BDados.preencherPeriodo(1, HorarioDisciplinaForm.CBDiscipina.Text, CInt(LPeriodo.Caption), LCurso.Caption)
    HorarioDisciplinaForm.discipinaTxt = ""
    Call BDados.preencherPeriodo(4, HorarioDisciplinaForm.discipinaTxt, CInt(LPeriodo.Caption), LCurso.Caption)

    Unload Me
End Sub
