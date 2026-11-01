VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
END
Attribute VB_Name = "Docentes"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = True
Private Sub PrencherTudo_Click()
    Dim docentesDesejado As String
    Dim posicaoDocente As Integer

    For i = 0 To 20
        posicaoDocente = i * 30 + 5
        If Not Docentes.Cells(posicaoDocente - 1, 2).Value Like "" Then
            Call BDados.preencherProfessor(Docentes.Cells(posicaoDocente - 2, 2).Value, posicaoDocente, Docentes.Cells(posicaoDocente - 1, 2).Value)
        Else
            Exit For
        End If
    Next i
End Sub
