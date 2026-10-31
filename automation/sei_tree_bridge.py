"""Bridge temporária entre a interface Flutter e a automação Selenium existente."""
from __future__ import annotations

import json
import os
import sys
import traceback
from pathlib import Path
from urllib.parse import urlparse


def emit(event: dict) -> None:
    print(json.dumps(event, ensure_ascii=False), flush=True)


def main() -> int:
    source_root = Path(
        os.environ.get(
            "PREENCHE_DIARIO_ROOT",
            str(Path(__file__).resolve().parents[2] / "PreencheDiario-UFU"),
        )
    )
    if not source_root.is_dir():
        emit({"type": "fatal", "message": f"Projeto de automação não encontrado: {source_root}"})
        return 2
    sys.path.insert(0, str(source_root))

    try:
        from services.drivers import create_driver
        from services.sei import AutomacaoSEI
    except Exception as exc:
        emit({"type": "fatal", "message": f"Não foi possível carregar a automação Selenium: {exc}"})
        return 2

    driver = None
    sei_host = ""

    def log(message: str) -> None:
        emit({"type": "log", "message": str(message)})

    try:
        for raw in sys.stdin:
            try:
                request = json.loads(raw)
                command = request.get("command")
                if command == "open_browser":
                    url = str(request.get("url", "")).strip()
                    parsed = urlparse(url)
                    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                        raise ValueError("Informe um endereço iniciado por http:// ou https://.")
                    if driver is None:
                        driver = create_driver(browser="edge", logger=log)
                    driver.get(url)
                    sei_host = parsed.hostname or ""
                    emit({"type": "browser_opened", "url": driver.current_url})
                elif command == "extract_tree":
                    if driver is None or not driver.window_handles:
                        raise RuntimeError("Abra o Edge pelo aplicativo e entre no processo SEI desejado.")
                    current_url = driver.current_url
                    current_host = urlparse(current_url).hostname or ""
                    if sei_host and current_host.casefold() != sei_host.casefold():
                        raise RuntimeError(
                            "O Edge não está no endereço do SEI configurado. Volte ao SEI e abra o processo desejado."
                        )
                    emit({"type": "started"})

                    def progress(index: int, total: int, name: str) -> None:
                        emit({"type": "progress", "current": index, "total": total, "name": name})

                    automation = AutomacaoSEI(driver, log)
                    documents = automation.extrair_arvore_processo(progresso=progress)
                    emit({
                        "type": "result",
                        "documents": [
                            {
                                "ordem": doc.ordem,
                                "nome_arvore": doc.nome_arvore,
                                "codigo_sei": doc.codigo_sei,
                                "tipo_numero": doc.tipo_numero,
                                "data": doc.data,
                                "resumo": doc.resumo,
                            }
                            for doc in documents
                        ],
                    })
                elif command == "shutdown":
                    emit({"type": "stopping"})
                    break
                else:
                    raise ValueError(f"Comando desconhecido: {command}")
            except Exception as exc:
                emit({"type": "error", "message": str(exc) or type(exc).__name__})
                traceback.print_exc(file=sys.stderr)
    finally:
        if driver is not None:
            try:
                driver.quit()
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
