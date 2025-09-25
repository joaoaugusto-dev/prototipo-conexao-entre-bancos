import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:dotenv/dotenv.dart';
import 'package:mysql_client/mysql_client.dart';

void main() async {
  final env = DotEnv()..load();

  final firebaseUrl = env['FIREBASE_URL'];
  if (firebaseUrl == null) {
    throw Exception('FIREBASE_URL não definida no arquivo .env');
  }

  final mysqlHost = env['MYSQL_HOST'];
  if (mysqlHost == null) {
    throw Exception('MYSQL_HOST não definida no arquivo .env');
  }

  final mysqlPort = env['MYSQL_PORT'];
  if (mysqlPort == null) {
    throw Exception('MYSQL_PORT não definida no arquivo .env');
  }

  final mysqlUser = env['MYSQL_USER'];
  if (mysqlUser == null) {
    throw Exception('MYSQL_USER não definida no arquivo .env');
  }

  final mysqlDatabase = env['MYSQL_DATABASE'];
  if (mysqlDatabase == null) {
    throw Exception('MYSQL_DATABASE não definida no arquivo .env');
  }

  final mysqlPassword = env['MYSQL_PASSWORD'] ?? '';

  final mysqlConn = await MySQLConnection.createConnection(
    host: mysqlHost,
    port: int.parse(mysqlPort),
    userName: mysqlUser,
    password: mysqlPassword,
    databaseName: mysqlDatabase,
  );
  await mysqlConn.connect();
  print('Conectado ao MySQL');

  try {
    await mysqlConn.execute(
      "INSERT IGNORE INTO setor (idsetores, nome, postosTrabalho, lotacao, TempSet, UmidSet, LumiSet) VALUES (1, 'Setor 1', 10, 20, 25, 60, 800)",
    );
    print('Setor padrão criado/verificado');
  } catch (e) {
    print('Aviso: Erro ao criar setor padrão: $e');
  }

  final random = Random();
  final tagsList = ["tag001", "tag002", "tag003", "tag004", "tag005", "tag006"];

  Timer.periodic(Duration(seconds: 5), (timer) async {
    final now = DateTime.now().toUtc();
    tagsList.shuffle(random);
    final tagsSelecionadas = tagsList.take(random.nextInt(4) + 1).join(", ");

    final data = {
      "data_hora": now.toString(),
      "id_setor": "S1",
      "luminosidade_atual": random.nextInt(1000),
      "tagsPresentes": tagsSelecionadas,
      "temperatura_atual": double.parse(
        (random.nextDouble() * 15 + 15).toStringAsFixed(1),
      ),
      "umidade_atual": random.nextInt(100),
    };

    final url = Uri.parse("$firebaseUrl.json");
    final response = await http.patch(url, body: jsonEncode(data));
    if (response.statusCode == 200) {
      print("Dados enviados ao Firebase: $data");
    } else {
      print("Erro ao enviar dados ao Firebase: ${response.statusCode}");
    }
  });

  Timer.periodic(Duration(seconds: 10), (timer) async {
    await sincronizarFirebaseParaMySQL(firebaseUrl, mysqlConn);
  });
}

Future<void> sincronizarFirebaseParaMySQL(
  String firebaseUrl,
  MySQLConnection conn,
) async {
  try {
    final url = Uri.parse("$firebaseUrl.json");
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final firebaseData = jsonDecode(response.body);

      if (firebaseData != null && firebaseData is Map) {
        final idSetorString = firebaseData['id_setor'] as String? ?? 'S1';
        final idSetor = int.tryParse(idSetorString.replaceAll('S', '')) ?? 1;

        final dataHoraString = firebaseData['data_hora'] as String?;
        final dataHora = dataHoraString != null
            ? DateTime.tryParse(dataHoraString)
            : DateTime.now();

        final temperatura = firebaseData['temperatura_atual'] as num? ?? 0.0;
        final umidade = firebaseData['umidade_atual'] as int? ?? 0;
        final luminosidade = firebaseData['luminosidade_atual'] as int? ?? 0;

        final insertResult = await conn.execute(
          "INSERT INTO dadoHistorico (data_hora, temperatura, umidade, luminosidade, setor_idsetores) VALUES ('${dataHora.toString()}', $temperatura, $umidade, $luminosidade, $idSetor)",
        );

        print("Dados inseridos no MySQL - ID: ${insertResult.lastInsertID}");

        final tagsPresentes = firebaseData['tagsPresentes'] as String? ?? '';
        if (tagsPresentes.isNotEmpty) {
          final tags = tagsPresentes.split(', ');
          for (final tag in tags) {
            final matricula =
                int.tryParse(tag.replaceAll('tag', '').replaceAll('0', '')) ??
                0;
            if (matricula > 0 && matricula <= 4) {
              try {
                await criarFuncionarioSeNaoExistir(conn, matricula, idSetor);

                await conn.execute(
                  "INSERT INTO presentes_historico (dadoHistorico_idhistorico_dados, funcionario_matricula) VALUES (${insertResult.lastInsertID}, $matricula)",
                );
              } catch (e) {
                print("Aviso: Erro ao processar matrícula $matricula: $e");
              }
            }
          }
        }
      }
    }
  } catch (e) {
    print("Erro na sincronização Firebase -> MySQL: $e");
  }
}

Future<void> criarFuncionarioSeNaoExistir(
  MySQLConnection conn,
  int matricula,
  int setorId,
) async {
  try {
    final result = await conn.execute(
      "SELECT matricula FROM funcionario WHERE matricula = $matricula",
    );

    if (result.rows.isEmpty) {
      await conn.execute(
        "INSERT INTO funcionario (matricula, nome, sobrenome, DataNasc, cargo, setor_idsetores) VALUES ($matricula, 'Funcionário', 'Tag$matricula', '1990-01-01', 'Operador', $setorId)",
      );
      print("Funcionário matrícula $matricula criado automaticamente");
    }
  } catch (e) {
    print("Erro ao criar funcionário $matricula: $e");
  }
}
