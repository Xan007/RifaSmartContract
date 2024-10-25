// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

contract Rifa is VRFConsumerBaseV2Plus {
    // Segundos
    uint256 constant TIEMPO_TURNO = 60;

    enum RifaState {
        Comprando,
        Generando,
        NumeroGenerado,
        Terminada
    }

    RifaState public estadoActual;

    // VRF Configuration
    uint256 public s_subscriptionId;
    address public vrfCoordinator = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    bytes32 public s_keyHash =
        0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
    uint32 public callbackGasLimit = 40000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;

    address ownerRifa;
    uint256 precioPorNumero;

    // Cola de compra
    mapping(uint256 => address) colaCompra;
    uint256 first = 1; // Índice del primer elemento
    uint256 last = 0; // Índice del último elemento

    // Numeros comprados de la rifa
    uint256[] numerosComprados;

    // Acceso a los numeros comprados y por quien fue comprado
    mapping(uint256 => address) numerosPorUsuario;
    mapping(address => uint256) usuarioPorNumero;

    // Validacion
    mapping(address => bool) usuarioEnCola;
    mapping(address => bool) usuarioCompro;

    uint256 ultimoTurnoTime;
    address usuarioActual;
    uint256 public numeroGanador;
    address public ultimoGanador;

    uint256 constant numeroMinimo = 1;
    uint256 numeroMaximo;
    uint256 requestId;

    bool locked;

    event usuarioComproNumero(address indexed usuario);
    event usuarioSiguiente(address indexed usuario);
    event turnoAsignado(address indexed usuario, uint256 posicion);

    constructor(uint256 subscriptionId) VRFConsumerBaseV2Plus(vrfCoordinator) {
        s_subscriptionId = subscriptionId;
        ownerRifa = msg.sender;
        estadoActual = RifaState.Terminada;
    }

    function fulfillRandomWords(uint256, uint256[] calldata randomWords) internal override {
        numeroGanador = uint256(randomWords[0] % numeroMaximo) + 1;

        estadoActual = RifaState.NumeroGenerado;
    }

    function generarGanador() public ownerOnly checkState(RifaState.Comprando) {
        require(numerosComprados.length == numeroMaximo, "Aun no se compran todos los numeros en la rifa");

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        estadoActual = RifaState.Generando;
    }

    function empezarRifa(uint256 _precioPorNumero, uint256 _numeroMaximo)
        public
        ownerOnly
        checkState(RifaState.Terminada)
    {
        numeroMaximo = _numeroMaximo;
        precioPorNumero = _precioPorNumero;
        estadoActual = RifaState.Comprando;
    }

    function terminarRifa() public payable ownerOnly checkState(RifaState.NumeroGenerado) {
        ultimoGanador = numerosPorUsuario[numeroGanador];
        
        if (precioPorNumero > 0) {
            uint256 totalRecaudado = address(this).balance;
            require(totalRecaudado > 0, "No hay Ether para enviar");

            uint256 etherGanadoPorNumero = precioPorNumero * (numeroMaximo);
            require(totalRecaudado >= etherGanadoPorNumero, "No se tiene el suficiente ether para dar el premio");

            address payable ganadorUsuario = payable(ultimoGanador);
            (bool sent, ) = ganadorUsuario.call{value: etherGanadoPorNumero}("");
            require(sent, "Fallo el envio de Ether a ganador");
        }

        // Limpiar la cola y datos de la rifa
        for (uint256 i = first; i <= last; i++) {
            address usuario = colaCompra[i];
            if (usuario != address(0)) {
                usuarioPorNumero[usuario] = 0;
                usuarioEnCola[usuario] = false;
                usuarioCompro[usuario] = false;
            }
        }
        first = 1;
        last = 0;
        delete numerosComprados;

        ultimoTurnoTime = 0;
        locked = false;
        precioPorNumero = 0;
        numeroGanador = 0;

        estadoActual = RifaState.Terminada;
    }

    // Añadir un usuario a la cola
    function hacerFila() public checkState(RifaState.Comprando) returns (uint256) {
        require(!usuarioEnCola[msg.sender], "Ya se encuentra en cola");
        require(!usuarioCompro[msg.sender], "Ya se compro un numero anteriormente");

        actualizarCola();

        last++;
        colaCompra[last] = msg.sender;
        usuarioEnCola[msg.sender] = true;

        if (first == last) {
            actualizarTurno(msg.sender);
        }

        uint posicionAsignada = last - first + 1;
        emit turnoAsignado(msg.sender, posicionAsignada); // Devolver la posición en la fila

        return posicionAsignada;
    }

    // [TODO] Esta funcion idealmente se tendria que llamar cada cierto tiempo de forma automatica.
    function actualizarCola() public returns (bool) {
        if (usuarioCompro[usuarioActual] || block.timestamp >= ultimoTurnoTime + TIEMPO_TURNO) {
            if (first <= last) {
                usuarioEnCola[colaCompra[first]] = false;
                delete colaCompra[first];
                first++;

                if (first <= last) {
                    actualizarTurno(colaCompra[first]);
                }

                return true;
            }
        }

        return false;
    }

    // Actualiza el turno y emite el evento correspondiente
    function actualizarTurno(address usuario) private {
        ultimoTurnoTime = block.timestamp;
        usuarioActual = usuario;
        emit usuarioSiguiente(usuario);
    }

    // Comprar un número revisando que esté en el frente de la fila
    function comprarNumero(uint256 numeroSolicitado)
        public payable
        checkState(RifaState.Comprando)
    {
        require(
            msg.value >= precioPorNumero,
            "Se requiere el precio correcto para comprar el numero"
        );
        require(!usuarioCompro[msg.sender], "Ya se compro un numero anteriormente");
        require(!locked, "Alguien se encuentra comprando, espere su turno.");
        require(first <= last, "No hay cola de compra. Primero haz fila");
        require(colaCompra[first] == msg.sender, "No te encuentras en el frente de la cola");
        require(numeroSolicitado > 0 && numeroSolicitado <= numeroMaximo, "El numero solicitado es invalido");
        require(numerosPorUsuario[numeroSolicitado] == address(0), "El numero ya fue comprado");

        locked = true;

        // Asignar el número al usuario
        numerosPorUsuario[numeroSolicitado] = msg.sender;
        usuarioPorNumero[msg.sender] = numeroSolicitado;
        numerosComprados.push(numeroSolicitado);
        usuarioCompro[msg.sender] = true;
        usuarioEnCola[msg.sender] = false;

        emit usuarioComproNumero(msg.sender);

        actualizarCola();

        locked = false;
    }

    function getColaCompra() public view returns (address[] memory) {
        address[] memory result;
        
        if (first <= last && last - first + 1 > 0) {
            result = new address[](last - first + 1);
            for (uint256 i = first; i <= last; i++) {
                result[i - first] = colaCompra[i];
            }
        } else {
            result = new address[](0);
        }

        return result;
    }

    function getPrecioPorNumero() public view returns (uint256, string memory) {
        return (precioPorNumero, "wei");
    }

    function getNumerosComprados() public view returns (uint256[] memory) {
        return numerosComprados;
    }

    function getNumerosDisponibles() public view  checkState(RifaState.Comprando) returns (uint256[] memory) {
        require(numeroMaximo > 0, "El numero maximo no ha sido establecido");

        uint256[] memory numerosDisponibles = new uint256[](numeroMaximo - numerosComprados.length);
        
        uint256 index = 0;
        for (uint256 i = 1; i <= numeroMaximo; ++i) {
            if (numerosPorUsuario[i] == address(0)) {
                numerosDisponibles[index] = i;
                index++;
            }
        }

        return numerosDisponibles;
    }

    modifier ownerOnly() {
        require(msg.sender == ownerRifa, "Esta funcion solo debe ser llamada por el owner");
        _;
    }

    modifier noReentrancy() {
        require(!locked, "Funcion en uso, espere su turno");
        locked = true;
        _;
        locked = false;
    }

    modifier checkState(RifaState estadoRequerido) {
        require(estadoActual == estadoRequerido, "Esta funcion no se puede llamar en el estado actual");
        _;
    }
}